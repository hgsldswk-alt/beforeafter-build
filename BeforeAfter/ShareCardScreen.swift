import SwiftUI

@MainActor
struct ShareCardScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "card.title") {
                TextAction("action.back", id: "card.back", symbol: "chevron.left") { model.exitCard() }
                    .disabled(model.busy)
            } trailing: {
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            }
            ScrollView {
                VStack(spacing: 14) {
                    preview
                    TextField(L.t("card.editTitle"), text: Binding(get: { model.cardDraft?.title ?? "" },
                                                                  set: { model.updateCardTitle($0) }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("card.titleField")
                    Toggle(L.t("card.qr"), isOn: Binding(get: { model.qrEnabled }, set: { model.updateQR($0) }))
                        .accessibilityIdentifier("card.qr")
                        .frame(minHeight: 44)
                    if model.qrEnabled && model.downloadURL == nil {
                        InlineMessage(key: "card.qrUnavailable")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    if let draft = model.cardDraft {
                        HStack(alignment: .top, spacing: 8) {
                            Text(L.f("topic.sentence", model.cardTitle, L.t(draft.topic)))
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 8)
                            TextAction("topic.copy", id: "card.copyTopic") { model.copyTopic() }
                        }
                        Picker(L.t("topic.title"), selection: Binding(get: { draft.topic }, set: { model.setTopic($0) })) {
                            Text(L.t("topic.tidyName")).tag("topic.tidy")
                            Text(L.t("topic.renovationName")).tag("topic.renovation")
                            Text(L.t("topic.craftName")).tag("topic.craft")
                        }
                        .accessibilityIdentifier("card.topic")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if draft.milestone != nil {
                            RowAction(title: L.t("milestone.choose"), id: "card.milestonePhotos") { model.panel = .milestonePhotos }
                            if draft.project != nil {
                                TextAction("milestone.remove", id: "card.removePhotos") { model.chooseMilestonePhoto(nil) }
                            }
                        }
                        if draft.project != nil {
                            RowAction(title: L.t("preset.share"), id: "card.sharePreset") { model.presetOptions = true }
                        }
                    }
                    if let text = model.message { InlineMessage(key: text) }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .disabled(model.busy)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    if model.busy {
                        ProgressView(L.t("work.progress"))
                        TextAction("action.cancel", id: "work.cancel") { model.cancelWork() }
                    } else {
                        PrimaryButton("card.share", id: "card.share") { model.shareCard() }
                            .disabled(model.cardPreview == nil)
                    }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.paper)
            }
        }
        .task(id: previewKey) {
            try? await Task.sleep(for: .milliseconds(140))
            if !Task.isCancelled { await model.updateCardPreview() }
        }
        .confirmationDialog(L.t("preset.share"), isPresented: $model.presetOptions, titleVisibility: .visible) {
            Button(L.t("preset.copy")) { model.copyPreset() }.accessibilityIdentifier("card.copyPreset")
            Button(L.t("preset.shareFile")) { model.sharePreset() }.accessibilityIdentifier("card.presetFile")
        }
    }

    private var preview: some View {
        Color.clear.aspectRatio(4.0 / 5, contentMode: .fit)
            .overlay {
                if let image = model.cardPreview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(L.t("card.preview"))
                        .accessibilityIdentifier("card.preview")
                } else {
                    ProgressView(L.t("app.loading"))
                }
            }
            .frame(maxWidth: 302)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(Theme.line) }
    }

    private var previewKey: String {
        (model.cardDraft?.project?.id.uuidString ?? "-") + "|" + model.cardTitle + "|" + String(model.qrEnabled)
    }
}
