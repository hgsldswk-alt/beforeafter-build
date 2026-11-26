import SwiftUI
import StoreKit

struct SizesScreen: View {
    @EnvironmentObject private var model: AppModel
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
                if Launch.freePeriod {
                    RowAction(title: L.t("size.high"), id: "size.high",
                              detail: OutputSize.high.pixels(for: project.layout).text, selected: project.output == .high) {
                        apply(.high)
                    }
                    Text(L.t("size.custom")).font(.headline).accessibilityAddTraits(.isHeader)
                    InlineMessage(key: "size.range")
                    customFields
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
        model.edit { $0.output = output }
        dismiss()
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
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
    @State private var code = ""

    var body: some View {
        PanelFrame(title: "preset.import") {
            if let stored = model.storedPreset {
                RowAction(title: L.t("preset.retained"), id: "preset.retained",
                          detail: stored.output.pixels(for: stored.layout).text) {
                    model.accept(stored)
                }
            }
            if model.testing, let testValue = ProcessInfo.processInfo.environment["BA_PRESET_TEXT"] {
                PrimaryButton("preset.paste", id: "preset.paste") { model.paste(testValue) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("preset.paste")).font(.headline)
                    PasteButton(payloadType: String.self) { items in
                        if let value = items.first { model.paste(value) }
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
            TextAction("action.apply", id: "preset.apply") { model.paste(code) }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            RowAction(title: L.t("preset.chooseFile"), id: "preset.file") { model.openFilePicker() }
            if let message = model.message { InlineMessage(key: message) }
        }
    }
}
