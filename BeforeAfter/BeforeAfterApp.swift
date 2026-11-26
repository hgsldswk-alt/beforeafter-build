import SwiftUI
import PhotosUI
import StoreKit
import QuickLook

@main
@MainActor
struct BeforeAfterApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

@MainActor
struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        Group {
            if model.ready {
                switch model.screen {
                case .home: HomeScreen()
                case .editor: EditorScreen()
                case .card: ShareCardScreen()
                }
            } else if model.startupFailed {
                VStack(spacing: 16) {
                    Text(L.t("error.startup")).multilineTextAlignment(.center)
                    PrimaryButton("action.retry", id: "startup.retry") { Task { await model.start() } }
                }
                .padding(24)
            } else {
                ProgressView(L.t("app.loading"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .tint(Theme.green)
        .preferredColorScheme(.light)
        .environmentObject(model)
        .task { await model.start() }
        .task(id: scenePhase) {
            if scenePhase == .active && model.ready { model.visit() }
        }
        .reviewAfterCoreAction(when: canCheckReview) { requestReview() }
        .task(id: canCheckReview) {
            guard canCheckReview else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, canCheckReview { model.requestExportReview { requestReview() } }
        }
        .onOpenURL { url in model.openDocument(url) }
        .quickLookPreview($model.previewURL)
        .photosPicker(isPresented: $model.pickerOpen, selection: $selection,
                      maxSelectionCount: model.selectionLimit, selectionBehavior: .ordered,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: selection) { _, picks in
            guard !picks.isEmpty else { return }
            model.receivePhotos(picks)
            selection = []
        }
        .fileImporter(isPresented: $model.pickingFiles, allowedContentTypes: [.beforeAfterPreset]) { response in
            switch response {
            case .success(let url): model.useDocument(url)
            case .failure: model.show("preset.invalid")
            }
        }
        .sheet(item: $model.panel, onDismiss: model.panelDidDismiss) { panel in
            panelView(panel)
                .environmentObject(model)
                .tint(Theme.green)
        }
        .sheet(item: $model.outputShare) { export in
            if export.fileOnly { SaveToFiles(url: export.url) { model.outputShare = nil } }
            else { ActivitySheet(url: export.url) { model.outputShare = nil } }
        }
        .sheet(isPresented: $model.fixtureOpen) {
            FixturePicker(limit: model.selectionLimit) { model.receiveFixture($0) }
        }
    }

    private var canCheckReview: Bool {
        scenePhase == .active && model.ready && model.screen == .home && model.panel == nil && !model.busy
            && !model.pickerOpen && !model.pickingFiles && !model.fixtureOpen && model.outputShare == nil
            && model.previewURL == nil && model.message == nil && model.undismissedMilestone == nil
    }

    @ViewBuilder private func panelView(_ panel: Panel) -> some View {
        switch panel {
        case .settings: SettingsScreen()
        case .history: HistoryScreen()
        case .sizes: SizesScreen()
        case .importPreset: PresetImportScreen()
        case .milestonePhotos: HistoryScreen(forMilestone: true)
        case .existingExports: ExistingExportsScreen()
        case .privacy: PrivacyScreen()
        }
    }
}
