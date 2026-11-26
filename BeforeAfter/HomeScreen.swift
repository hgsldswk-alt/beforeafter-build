import SwiftUI

@MainActor
struct HomeScreen: View {
    @EnvironmentObject private var model: AppModel
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: nil) {
                EmptyView()
            } trailing: {
                TextAction("settings.title", id: "home.settings") { model.panel = .settings }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L.t("home.headline"))
                        .font(.system(size: titleSize, weight: .heavy))
                        .tracking(-1.1)
                        .accessibilityAddTraits(.isHeader)
                    if model.recent == nil { sample }
                    VStack(spacing: 8) {
                        PrimaryButton("home.pick", id: "home.pick", symbol: "plus") { model.requestPhotos() }
                            .disabled(model.busy)
                        Text(L.t("home.pickHint"))
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                        TextAction("preset.import", id: "home.importPreset") { model.panel = .importPreset }
                            .disabled(model.busy)
                    }
                    if let milestone = model.undismissedMilestone { milestoneRow(milestone) }
                    if let recent = model.recent {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L.t("home.recent")).font(.headline).accessibilityAddTraits(.isHeader)
                            RowAction(title: recent.title ?? L.t("project.untitled"), id: "home.recent",
                                      detail: projectStatus(recent)) { model.open(recent) }
                                .disabled(model.busy)
                            TextAction("history.title", id: "home.history", symbol: "clock") { model.panel = .history }
                        }
                    }
                    if model.busy {
                        ProgressView(L.t("photo.loading"))
                        TextAction("action.cancel", id: "work.cancel") { model.cancelWork() }
                    }
                    if let message = model.message { InlineMessage(key: message) }
                }
                .frame(maxWidth: 490)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            Text(L.t("home.local"))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
    }

    private var sample: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                samplePhoto("entry-before", .before)
                samplePhoto("entry-after", .after)
            }
            HStack {
                Text(L.t("home.sampleTitle")).font(.footnote.weight(.semibold))
                Spacer()
                Text(L.t("home.sample")).font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 3)
        }
        .padding(11)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 23))
        .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(Theme.line) }
    }

    private func samplePhoto(_ name: String, _ slot: Slot) -> some View {
        VStack(spacing: 0) {
            Color(uiColor: Palette.tile)
                .aspectRatio(3.0 / 4, contentMode: .fit)
                .overlay {
                    Image(name).resizable().scaledToFit()
                }
                .accessibilityHidden(true)
            Text(L.t(slot.key))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Color(uiColor: Palette.label(slot)))
                .foregroundStyle(Theme.green)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func milestoneRow(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RowAction(title: L.f("milestone.title", count), id: "home.milestone",
                      detail: L.t("milestone.make")) { model.makeCard(milestone: count) }
            TextAction("milestone.dismiss", id: "home.dismissMilestone") { model.dismissMilestone(count) }
        }
    }
}

func projectStatus(_ project: ComparisonProject) -> String {
    let status = L.t(project.lastExportID == nil ? "project.draft" : "project.exported")
    return L.f("project.status", status, project.modified.formatted(date: .abbreviated, time: .omitted))
}

struct FixturePicker: View {
    let limit: Int
    let complete: ([String]) -> Void
    @State private var selection: [String] = []

    private let names = ["entry-before", "entry-after", "wide-before", "wide-after", "invalid-photo"]

    var body: some View {
        PanelFrame(title: "home.pick") {
            ForEach(names, id: \.self) { name in
                RowAction(title: name, id: "fixture." + name, selected: selection.contains(name)) {
                    if let index = selection.firstIndex(of: name) { selection.remove(at: index) }
                    else if selection.count < limit { selection.append(name) }
                }
            }
            PrimaryButton("action.apply", id: "fixture.confirm") { complete(selection) }
                .disabled(selection.isEmpty)
        }
    }
}
