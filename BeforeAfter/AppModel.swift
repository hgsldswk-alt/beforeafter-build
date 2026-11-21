import SwiftUI
import PhotosUI
import StoreKit
import UniformTypeIdentifiers

enum AppScreen: Equatable { case home, editor, card }
enum ExistingExportAction { case preview, share, savePhotos }
enum Panel: String, Identifiable {
    case settings, history, sizes, paywall, importPreset, milestonePhotos, existingExports, privacy
    var id: String { rawValue }
}

struct ExportPresentation: Identifiable {
    let id = UUID()
    let url: URL
    let fileOnly: Bool
}

struct ImportRequest {
    var slots = Slot.allCases
    var existing: ComparisonProject?
    var preset: PresetV1?
    var useBasic = false
}

struct ShareCardDraft {
    var id = UUID()
    var title: String
    var project: ComparisonProject?
    var milestone: Int?
    var topic = "topic.tidy"
    var titleEdited = false
}

@MainActor
final class AppModel: ObservableObject {
    let testing: Bool
    let store: ProjectStore
    private let arguments = ProcessInfo.processInfo.arguments
    private let defaults: UserDefaults
    private var pendingDraft: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var pendingOpen: (url: URL, hasPro: () -> Bool)?
    private var afterPanelDismissal: (() -> Void)?
    private var afterPresetDismissal: (() -> Void)?
    private var reviewHistory = ReviewHistory()
    private let launchDay = Date()
    private var blockedReview = false
    private var didStart = false

    @Published private(set) var ready = false
    @Published private(set) var startupFailed = false
    @Published private(set) var index = ProjectIndex()
    @Published private(set) var project: ComparisonProject?
    @Published private(set) var thumbnails: [Slot: UIImage] = [:]
    @Published private(set) var busy = false
    @Published private(set) var savingPhoto = false
    @Published private(set) var saved = false
    @Published private(set) var fallback: URL?
    @Published var message: String?
    @Published var screen: AppScreen = .home
    @Published var panel: Panel?
    @Published var pickerOpen = false
    @Published var fixtureOpen = false
    @Published var pickingFiles = false
    @Published var outputShare: ExportPresentation?
    @Published var previewURL: URL?
    @Published var deferredPreset: PresetV1?
    @Published var cardDraft: ShareCardDraft?
    @Published var cardPreview: UIImage?
    @Published var qrEnabled: Bool
    @Published var shareOptions = false
    @Published var presetOptions = false
    @Published var storedPreset: PresetV1?
    private var cardBack: AppScreen = .editor
    private var importRequest: ImportRequest?

    init() {
        testing = Launch.testing
        let testSuite = "com.hgsldswk.beforeafter.ui"
        let settings = testing ? (UserDefaults(suiteName: testSuite) ?? .standard) : .standard
        if testing && arguments.contains("-reset") { settings.removePersistentDomain(forName: testSuite) }
        defaults = settings
        qrEnabled = settings.object(forKey: "share.qr") as? Bool ?? true
        store = ProjectStore(root: ProjectStore.defaultRoot(testing: testing))
    }

    var recent: ComparisonProject? { history.first }
    var history: [ComparisonProject] { index.projects.sorted { $0.modified > $1.modified } }
    var undismissedMilestone: Int? { index.milestone.flatMap { $0 > (index.savedMilestone ?? 0) ? $0 : nil } }
    var records: [ExportRecord] {
        guard let project else { return [] }
        return index.exports.reversed().filter { $0.projectID == project.id }
    }
    var hasCleanExports: Bool { records.contains { $0.isCollage } }

    var downloadURL: URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + raw)
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            index = try await store.prepare(reset: testing && arguments.contains("-reset"))
            if !testing, let data = defaults.data(forKey: "review.history"),
               let restored = try? JSONDecoder().decode(ReviewHistory.self, from: data) {
                reviewHistory = restored
            }
            visit(launchDay)
            if let data = defaults.data(forKey: "preset.retained") {
                storedPreset = try? PresetV1(data: data)
            }
            startupFailed = false
            ready = true
            if testing && arguments.contains("-paywall") { openPaywall() }
            processPendingDocument()
        } catch {
            startupFailed = true
            didStart = false
        }
    }

    func requestPhotos(slot: Slot? = nil, preset: PresetV1? = nil, useBasic: Bool = false) {
        guard ready, !busy else { return }
        if let slot, let project {
            importRequest = ImportRequest(slots: [slot], existing: project)
        } else {
            importRequest = ImportRequest(preset: preset, useBasic: useBasic)
        }
        message = nil
        if testing && !arguments.contains("-native-picker") {
            fixtureOpen = true
        } else {
            pickerOpen = true
        }
    }

    var selectionLimit: Int { importRequest?.slots.count ?? 2 }

    func receivePhotos(_ picks: [PhotosPickerItem]) {
        guard !picks.isEmpty else { return }
        importPhotos(count: picks.count) { position in
            guard let incoming = try await picks[position].loadTransferable(type: IncomingPhoto.self) else {
                throw CollageError.unreadablePhoto
            }
            return (incoming.url, true)
        }
    }

    func receiveFixture(_ names: [String]) {
        fixtureOpen = false
        importPhotos(count: names.count) { position in
            guard let url = Bundle.main.url(forResource: names[position], withExtension: "jpg", subdirectory: "Fixtures") else {
                throw CollageError.unreadablePhoto
            }
            return (url, false)
        }
    }

    private func importPhotos(count: Int, load: @escaping (Int) async throws -> (URL, Bool)) {
        guard !busy, let request = importRequest else { return }
        importRequest = nil
        run { [self] in
            var draft = request.existing ?? ComparisonProject()
            request.preset?.apply(to: &draft, useBasic: request.useBasic)
            var countAdded = 0
            var failure: Error?
            for (position, slot) in request.slots.prefix(count).enumerated() {
                if Task.isCancelled { break }
                do {
                    let (url, temporary) = try await load(position)
                    defer { if temporary { try? FileManager.default.removeItem(at: url) } }
                    let asset = try await store.importPhoto(url)
                    draft[slot] = PlacedPhoto(asset: asset)
                    draft.applyAutomaticLayout()
                    draft.touch()
                    index = try await store.upsert(draft)
                    project = draft
                    countAdded += 1
                } catch is CancellationError {
                    break
                } catch {
                    failure = error
                }
            }
            if countAdded > 0 {
                thumbnails = await store.thumbnails(draft)
                saved = false
                fallback = nil
                screen = .editor
            }
            if let failure {
                if isLowSpace(failure) { show(failure) }
                else { show(countAdded > 0 ? "photo.importError" : "photo.importNone") }
            } else if countAdded > 0 && !draft.isComplete {
                message = "photo.incomplete"
            }
        }
    }

    func open(_ draft: ComparisonProject) {
        guard !busy else { return }
        panel = nil
        run { [self] in
            project = draft
            thumbnails = await store.thumbnails(draft)
            fallback = nil
            saved = index.exports.contains {
                $0.projectID == draft.id && $0.revision == draft.revision && $0.isCollage && $0.savedToPhotos
            }
            message = nil
            screen = .editor
        }
    }

    func edit(_ change: (inout ComparisonProject) -> Void) {
        guard !busy, var draft = project else { return }
        change(&draft)
        guard draft != project else { return }
        draft.clampPoses()
        draft.touch()
        project = draft
        saved = false
        fallback = nil
        message = nil
        persist(draft)
    }

    func swap() {
        guard !busy, project?.isComplete == true else { return }
        edit { $0.swapPhotos() }
        let previous = thumbnails
        thumbnails = [.before: previous[.after], .after: previous[.before]].compactMapValues { $0 }
    }

    func basicCopy() {
        guard !busy, let copy = project?.basicCopy() else { return }
        project = copy
        saved = false
        fallback = nil
        message = nil
        persist(copy)
    }

    private func persist(_ draft: ComparisonProject) {
        let prior = pendingDraft
        pendingDraft = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                index = try await store.upsert(draft)
            } catch {
                show(error)
            }
        }
    }

    func leaveEditor() {
        guard !busy else { return }
        screen = .home
        message = nil
        fallback = nil
    }

    func save(hasPro: Bool) {
        guard let draft = project, draft.isComplete, !busy else { return }
        if draft.output.isAdvanced && !hasPro { openPaywall(); return }
        if saved { return }
        if !testing { blockedReview = true }
        run { [self] in
            let (record, url) = try await generate(draft)
            fallback = url
            try Task.checkCancellation()
            try await addToPhotos(record, url: url)
        }
    }

    private func generate(_ draft: ComparisonProject) async throws -> (ExportRecord, URL) {
        index = try await store.upsert(draft)
        let (record, url, updated) = try await store.generate(draft)
        index = updated
        project = updated.projects.first { $0.id == draft.id }
        return (record, url)
    }

    private func addToPhotos(_ record: ExportRecord, url: URL) async throws {
        try Task.checkCancellation()
        savingPhoto = true
        defer { savingPhoto = false }
        if testing {
            if arguments.contains("-deny-photos") { throw CollageError.photoDenied }
        } else {
            try await PhotoLibrary.save(url)
        }
        if record.isCollage && project?.id == record.projectID && project?.revision == record.revision { saved = true }
        fallback = nil
        index = try await store.markPhotosSaved(record.id)
    }

    func shareClean(hasPro: Bool) {
        guard let draft = project, !busy else { return }
        blockReview()
        run { [self] in
            let url: URL
            if draft.isComplete && (hasPro || !draft.output.isAdvanced) {
                (_, url) = try await generate(draft)
            } else {
                (_, url) = try await store.newestUsableExport(for: draft.id)
            }
            outputShare = ExportPresentation(url: url, fileOnly: false)
        }
    }

    func openExport(_ record: ExportRecord, action: ExistingExportAction) {
        afterClosingPanel { [weak self] in self?.deliverExistingExport(record, action: action) }
    }

    private func deliverExistingExport(_ record: ExportRecord, action: ExistingExportAction) {
        blockReview()
        run { [self] in
            let url = try await store.exportURL(record)
            switch action {
            case .preview:
                previewURL = url
            case .savePhotos:
                fallback = url
                try await addToPhotos(record, url: url)
            case .share:
                outputShare = ExportPresentation(url: url, fileOnly: false)
            }
        }
    }

    func saveFile() {
        guard let fallback else { return }
        blockReview()
        outputShare = ExportPresentation(url: fallback, fileOnly: true)
    }

    func openPaywall() {
        blockReview()
        panel = .paywall
    }

    func accept(_ preset: PresetV1, hasPro: Bool) {
        afterClosingPanel { [weak self] in
            guard let self else { return }
            if preset.output.isAdvanced && !hasPro {
                self.deferredPreset = preset
            } else {
                self.requestPhotos(preset: preset)
            }
        }
    }

    func finishDeferredPreset(useBasic: Bool) {
        guard let preset = deferredPreset else { return }
        retain(preset)
        if useBasic {
            afterPresetDismissal = { [weak self] in self?.requestPhotos(preset: preset, useBasic: true) }
        }
        deferredPreset = nil
    }

    func presetDidDismiss() {
        let pending = afterPresetDismissal
        afterPresetDismissal = nil
        pending?()
    }

    func paste(_ code: String, hasPro: Bool) {
        do { accept(try PresetV1(code: code), hasPro: hasPro) }
        catch { show("preset.invalid") }
    }

    func openDocument(_ url: URL, hasPro: @escaping () -> Bool) {
        pendingOpen = (url, hasPro)
        processPendingDocument()
    }

    private func processPendingDocument() {
        guard ready, !busy, let (url, hasPro) = pendingOpen else { return }
        pendingOpen = nil
        readPresetFile(url, hasPro: hasPro)
    }

    func openFilePicker() {
        afterClosingPanel { [weak self] in self?.pickingFiles = true }
    }

    func panelDidDismiss() {
        let pending = afterPanelDismissal
        afterPanelDismissal = nil
        pending?()
    }

    private func afterClosingPanel(_ task: @escaping () -> Void) {
        if panel == nil { task(); return }
        afterPanelDismissal = task
        panel = nil
    }

    private func readPresetFile(_ url: URL, hasPro: @escaping () -> Bool) {
        run { [self] in
            do {
                let preset = try await store.readPreset(url)
                acceptAfterRun = (preset, hasPro())
            } catch {
                show("preset.invalid")
            }
        }
    }

    func useDocument(_ url: URL, hasPro: Bool) {
        readPresetFile(url, hasPro: { hasPro })
    }

    private func retain(_ preset: PresetV1) {
        storedPreset = preset
        if let data = try? preset.data { defaults.set(data, forKey: "preset.retained") }
    }

    private var acceptAfterRun: (PresetV1, Bool)?

    func makeCard(milestone: Int? = nil) {
        guard !busy else { return }
        let source = milestone == nil ? project : nil
        guard milestone != nil || source?.isComplete == true else { return }
        blockReview()
        cardBack = screen
        cardPreview = nil
        let cardTitleKey = testing && arguments.contains("-store-shots") ? "card.sampleTitle" : "card.defaultTitle"
        cardDraft = ShareCardDraft(title: milestone.map { L.f("milestone.title", $0) }
                                   ?? source?.title ?? L.t(cardTitleKey),
                                   project: source, milestone: milestone)
        screen = .card
    }

    func chooseMilestonePhoto(_ draft: ComparisonProject?) {
        guard var card = cardDraft else { return }
        card.project = draft
        cardDraft = card
        panel = nil
    }

    func updateCardTitle(_ value: String) {
        guard var draft = cardDraft else { return }
        draft.title = String(value.prefix(64))
        draft.titleEdited = true
        cardDraft = draft
    }

    private func rememberCardTitle(_ card: ShareCardDraft) {
        guard card.milestone == nil, card.titleEdited, var project, project.id == card.project?.id else { return }
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = title.isEmpty ? nil : title
        guard project.title != updated else { return }
        project.title = updated
        project.modified = Date()
        self.project = project
        persist(project)
    }

    func setTopic(_ key: String) { cardDraft?.topic = key }

    var cardTitle: String {
        let value = cardDraft?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? L.t("card.defaultTitle") : value
    }

    func updateQR(_ enabled: Bool) {
        qrEnabled = enabled
        defaults.set(enabled, forKey: "share.qr")
    }

    func updateCardPreview() async {
        guard let draft = cardDraft else { return }
        let title = cardTitle
        let qr = qrEnabled
        do {
            let result = try await store.renderCardPreview(title: title, project: draft.project,
                                                          qr: qr ? downloadURL : nil, placeholder: qr,
                                                          milestone: draft.milestone)
            guard !Task.isCancelled, screen == .card else { return }
            cardPreview = result
        } catch {
            if !Task.isCancelled { show(error) }
        }
    }

    func shareCard() {
        guard let draft = cardDraft, !busy else { return }
        let title = cardTitle
        rememberCardTitle(draft)
        run { [self] in
            let source = draft.milestone == nil ? project : draft.project
            let (url, updated) = try await store.writeCard(title: title, project: source,
                                                           qr: qrEnabled ? downloadURL : nil, milestone: draft.milestone)
            if let updated, let source {
                index = updated
                project = updated.projects.first { $0.id == source.id }
            }
            if let milestone = draft.milestone { index = try await store.acknowledgeMilestone(milestone) }
            outputShare = ExportPresentation(url: url, fileOnly: false)
        }
    }

    func exitCard() {
        guard !busy else { return }
        if let cardDraft { rememberCardTitle(cardDraft) }
        cardDraft = nil
        cardPreview = nil
        screen = cardBack
        message = nil
    }

    func sharePreset() {
        guard let project = cardDraft?.project else { return }
        run { [self] in
            let url = try await store.writePreset(PresetV1(project: project))
            outputShare = ExportPresentation(url: url, fileOnly: false)
        }
    }

    func copyPreset() {
        guard let project = cardDraft?.project else { return }
        do {
            UIPasteboard.general.string = try PresetV1(project: project).code
            message = "preset.copied"
        } catch {
            show(error)
        }
    }

    func copyTopic() {
        guard let draft = cardDraft else { return }
        UIPasteboard.general.string = L.f("topic.sentence", cardTitle, L.t(draft.topic))
        message = "topic.copied"
    }

    func visit(_ date: Date = Date()) {
        guard !testing else { return }
        reviewHistory.visit(date)
        writeReviewHistory()
    }

    func checkReview() -> Bool {
        let now = Date()
        guard !testing, ready, screen == .home, !busy, panel == nil, !pickerOpen,
              !pickingFiles, outputShare == nil, deferredPreset == nil, message == nil,
              undismissedMilestone == nil,
              reviewHistory.eligible(at: now, exports: index.distinctExports, blocked: blockedReview)
        else { return false }
        reviewHistory.record(now)
        writeReviewHistory()
        return true
    }

    func dismissMilestone(_ count: Int) {
        run { [self] in index = try await store.acknowledgeMilestone(count) }
    }

    private func writeReviewHistory() {
        if let data = try? JSONEncoder().encode(reviewHistory) { defaults.set(data, forKey: "review.history") }
    }

    private func blockReview() { blockedReview = true }

    func show(_ key: String) {
        blockReview()
        message = key
    }

    private func show(_ error: Error) {
        if error is CancellationError { return }
        switch error as? CollageError {
        case .photoDenied: show("photo.denied")
        case .lowSpace: show("error.space")
        case .missingFile: show("error.file")
        case .invalidSize: show("size.invalid")
        default:
            show(isLowSpace(error) ? "error.space" : "error.operation")
        }
    }

    private func isLowSpace(_ error: Error) -> Bool {
        if case .some(.lowSpace) = error as? CollageError { return true }
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        let prior = pendingDraft
        operation = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            defer {
                busy = false
                operation = nil
                if let (preset, hasPro) = acceptAfterRun {
                    acceptAfterRun = nil
                    accept(preset, hasPro: hasPro)
                }
                processPendingDocument()
            }
            do { try await work() }
            catch { show(error) }
        }
    }

    func cancelWork() { if !savingPhoto { operation?.cancel() } }
}
