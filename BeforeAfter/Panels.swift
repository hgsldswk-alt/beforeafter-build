import SwiftUI
import StoreKit

struct SizesScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var height = ""
    @State private var invalid = false

    var body: some View {
        PanelFrame(title: "size.title") {
            if let project = model.project {
                RowAction(title: L.t("size.basic"), id: "size.basic",
                          detail: OutputSize.basic.pixels(for: project.layout).text, selected: project.output == .basic) {
                    apply(.basic)
                }
                RowAction(title: L.t("size.high"), id: "size.high",
                          detail: OutputSize.high.pixels(for: project.layout).text, selected: project.output == .high) {
                    if purchases.hasPro { apply(.high) } else { model.openPaywall() }
                }
                if purchases.hasPro {
                    Text(L.t("size.custom")).font(.headline).accessibilityAddTraits(.isHeader)
                    InlineMessage(key: "size.range")
                    customFields
                } else {
                    RowAction(title: L.t("size.custom"), id: "size.custom", detail: L.t("size.range")) {
                        model.openPaywall()
                    }
                }
                InlineMessage(key: "size.smallPhoto")
            }
        }
        .onAppear {
            if case let .some(.custom(pixels)) = model.project?.output {
                width = String(pixels.width)
                height = String(pixels.height)
            }
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(L.t("size.width"), text: $width)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("size.width")
            TextField(L.t("size.height"), text: $height)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("size.height")
            if let value = customPixels, value.validCustom {
                Text(value.text).monospacedDigit().accessibilityIdentifier("size.customPreview")
            }
            if invalid { InlineMessage(key: "size.invalid") }
            PrimaryButton("action.apply", id: "size.apply") {
                guard purchases.hasPro else { model.openPaywall(); return }
                guard let value = customPixels, value.validCustom else { invalid = true; return }
                apply(.custom(value))
            }
        }
    }

    private var customPixels: Pixels? {
        guard let width = Int(width), let height = Int(height) else { return nil }
        return Pixels(width: width, height: height)
    }

    private func apply(_ output: OutputSize) {
        if output == .basic && model.project?.output.isAdvanced == true && !purchases.hasPro {
            model.basicCopy()
        } else {
            model.edit { $0.output = output }
        }
        dismiss()
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        PanelFrame(title: "settings.title") {
            Toggle(L.t("card.qr"), isOn: Binding(get: { model.qrEnabled }, set: { model.updateQR($0) }))
                .accessibilityIdentifier("settings.qr")
            if let url = model.downloadURL {
                ShareLink(item: url) { Text(L.t("settings.recommend")).frame(minHeight: 44) }
                    .accessibilityIdentifier("settings.recommend")
            } else {
                ShareLink(item: L.t("settings.recommendText")) {
                    Text(L.t("settings.recommend")).frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.recommend")
            }
            RowAction(title: L.t("settings.review"), id: "settings.review") { requestReview() }
            RowAction(title: L.t("privacy.title"), id: "settings.privacy") { model.panel = .privacy }
            if !purchases.free {
                RowAction(title: L.t("pay.title"), id: "settings.pro") { model.openPaywall() }
                RowAction(title: L.t("pay.restore"), id: "settings.restore") {
                    Task { await purchases.restore() }
                }
                .disabled(purchases.busy)
                if let notice = purchases.notice { InlineMessage(key: notice) }
            }
        }
    }
}

struct PrivacyScreen: View {
    var body: some View {
        PanelFrame(title: "privacy.title") {
            Text(L.t("privacy.body")).foregroundStyle(Theme.muted)
        }
    }
}

struct PaywallScreen: View {
    @EnvironmentObject private var purchases: Purchases

    var body: some View {
        PanelFrame(title: "pay.title") {
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("pay.heading"))
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(L.t("pay.details")).foregroundStyle(Theme.muted)
                Text(L.t("pay.basic")).font(.footnote).foregroundStyle(Theme.muted)
                Text(purchases.paid ? L.t("pay.owned")
                     : purchases.remainingDays == 0 ? L.t("pay.expired") : L.f("pay.remaining", purchases.remainingDays))
                    .font(.headline)
                    .foregroundStyle(Theme.green)
                    .accessibilityIdentifier("pay.status")
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 16))
            if !purchases.paid {
                if let product = purchases.pro {
                    PrimaryButton("pay.buy", id: "pay.buy") { Task { await purchases.purchase(product) } }
                    Text(L.f("pay.price", product.displayPrice)).font(.footnote).foregroundStyle(Theme.muted)
                } else if purchases.testing {
                    PrimaryButton("pay.buy", id: "pay.buy") {}.disabled(true)
                    InlineMessage(key: "pay.previewPrice")
                } else {
                    InlineMessage(key: "pay.priceUnavailable")
                    TextAction("action.retry", id: "pay.retry") { Task { await purchases.loadProducts() } }
                }
                if purchases.remainingDays > 0 && purchases.entitlement?.trialClaimedAt == nil {
                    if let trial = purchases.trial {
                        RowAction(title: L.t("pay.claim"), id: "pay.claim",
                                  detail: L.f("pay.trialPrice", trial.displayPrice)) {
                            Task { await purchases.purchase(trial) }
                        }
                    } else if purchases.testing {
                        RowAction(title: L.t("pay.claim"), id: "pay.claim", detail: L.t("pay.trialExplanation")) {}
                            .disabled(true)
                    }
                }
            }
            RowAction(title: L.t("pay.restore"), id: "pay.restore") { Task { await purchases.restore() } }
                .disabled(purchases.busy)
            if purchases.busy { ProgressView(L.t("work.progress")) }
            if let notice = purchases.notice { InlineMessage(key: notice) }
        }
        .task { await purchases.loadProducts() }
    }
}

struct HistoryScreen: View {
    @EnvironmentObject private var model: AppModel
    var forMilestone = false

    var body: some View {
        PanelFrame(title: forMilestone ? "milestone.choose" : "history.title") {
            let entries = forMilestone ? model.history.filter(\.isComplete) : model.history
            if entries.isEmpty { InlineMessage(key: "history.empty") }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, project in
                RowAction(title: project.title ?? L.t("project.untitled"), id: "history.project.\(index)",
                          detail: projectStatus(project)) {
                    if forMilestone { model.chooseMilestonePhoto(project) }
                    else { model.open(project) }
                }
            }
        }
    }
}

struct ExistingExportsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PanelFrame(title: "editor.exports") {
            ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                VStack(alignment: .leading, spacing: 2) {
                    RowAction(title: L.f(record.isCollage ? "export.original" : "export.card", record.pixels.text), id: "exports.preview.\(index)",
                              detail: record.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        model.openExport(record, action: .preview)
                    }
                    HStack {
                        TextAction("editor.share", id: "exports.share.\(index)") { model.openExport(record, action: .share) }
                        TextAction("export.saveCopy", id: "exports.save.\(index)") { model.openExport(record, action: .savePhotos) }
                    }
                }
            }
        }
    }
}

struct PresetImportScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @State private var code = ""

    var body: some View {
        PanelFrame(title: "preset.import") {
            if let stored = model.storedPreset {
                RowAction(title: L.t("preset.retained"), id: "preset.retained",
                          detail: stored.output.pixels(for: stored.layout).text) {
                    model.accept(stored, hasPro: purchases.hasPro)
                }
            }
            if model.testing, let testValue = ProcessInfo.processInfo.environment["BA_PRESET_TEXT"] {
                PrimaryButton("preset.paste", id: "preset.paste") { model.paste(testValue, hasPro: purchases.hasPro) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("preset.paste")).font(.headline)
                    PasteButton(payloadType: String.self) { items in
                        if let value = items.first { model.paste(value, hasPro: purchases.hasPro) }
                    }
                    .accessibilityIdentifier("preset.paste")
                    .frame(minHeight: 44)
                }
            }
            TextField(L.t("preset.enter"), text: $code)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("preset.code")
            TextAction("action.apply", id: "preset.apply") { model.paste(code, hasPro: purchases.hasPro) }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            RowAction(title: L.t("preset.chooseFile"), id: "preset.file") { model.openFilePicker() }
            if let message = model.message { InlineMessage(key: message) }
        }
    }
}

struct DeferredPresetScreen: View {
    let preset: PresetV1
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PanelFrame(title: "preset.advanced") {
            Text(L.f("preset.compare", preset.output.pixels(for: preset.layout).text,
                     OutputSize.basic.pixels(for: preset.layout).text))
                .foregroundStyle(Theme.muted)
            PrimaryButton("editor.basicCopy", id: "preset.basic") { model.finishDeferredPreset(useBasic: true) }
            RowAction(title: L.t("preset.keep"), id: "preset.keep") { model.finishDeferredPreset(useBasic: false) }
        }
    }
}
