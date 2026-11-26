import SwiftUI

@MainActor
struct EditorScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var type
    @State private var alignment = false
    @State private var active: Slot = .before

    var body: some View {
        VStack(spacing: 0) {
            if let project = model.project {
                TopBar(title: "editor.title") {
                    TextAction("action.back", id: "editor.back", symbol: "chevron.left") {
                        model.leaveEditor()
                    }
                    .disabled(model.busy)
                } trailing: {
                    TextAction("editor.share", id: "editor.share") { model.shareOptions = true }
                        .disabled(model.busy || (!project.isComplete && !model.hasCleanExports))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        canvas(project)
                        layouts(project)
                        tools(project)
                        if alignment { InlineMessage(key: "editor.gestures") }
                        if !model.records.isEmpty {
                            TextAction("editor.exports", id: "editor.exports", symbol: "tray.full") {
                                model.panel = .existingExports
                            }
                            .disabled(model.busy)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actions(project)
                }
                .confirmationDialog(L.t("editor.share"), isPresented: $model.shareOptions, titleVisibility: .visible) {
                    Button(L.t("editor.shareClean")) { model.shareClean() }
                        .accessibilityIdentifier("editor.shareClean")
                        .disabled(!(project.isComplete && (Launch.freePeriod || !project.output.isAdvanced)) && !model.hasCleanExports)
                    Button(L.t("editor.shareCard")) { model.makeCard() }
                        .accessibilityIdentifier("editor.shareCard")
                        .disabled(!project.isComplete)
                }
                .onChange(of: project.id) { _, _ in
                    alignment = false
                    active = .before
                }
            }
        }
    }

    private func canvas(_ project: ComparisonProject) -> some View {
        VStack(spacing: 10) {
            let size = project.pixels.size
            Color.clear
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .frame(maxHeight: 405)
                .overlay { canvasContent(project) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(L.t("size.output"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(project.pixels.text)
                    .monospacedDigit()
                    .accessibilityIdentifier("editor.dimensions")
            }
            .font(.footnote)
            .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 21))
        .overlay { RoundedRectangle(cornerRadius: 21).strokeBorder(Theme.line) }
    }

    private func canvasContent(_ project: ComparisonProject) -> some View {
        GeometryReader { proxy in
            let geometry = CollageGeometry(project: project)
            let scale = min(proxy.size.width / geometry.size.width, proxy.size.height / geometry.size.height)
            let width = geometry.size.width * scale
            let height = geometry.size.height * scale
            ZStack(alignment: .topLeading) {
                Theme.surface
                ForEach(Slot.allCases, id: \.self) { slot in
                    let tile = geometry.tile(slot).applying(CGAffineTransform(scaleX: scale, y: scale))
                    PhotoTile(project: project, slot: slot, geometry: geometry, scale: scale,
                              image: model.thumbnails[slot], aligning: alignment,
                              selected: alignment && slot == active, tap: {
                        if alignment && project[slot] != nil { active = slot }
                        else { model.requestPhotos(slot: slot) }
                    }, adjust: { pose in
                        model.edit { $0[slot]?.pose = pose }
                    })
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: tile.minX, y: tile.minY)
                    .disabled(model.busy)
                }
            }
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func layouts(_ project: ComparisonProject) -> some View {
        HStack(spacing: 5) {
            ForEach(Layout.allCases, id: \.self) { layout in
                ToolButton(key: layout.key, id: layout == .sideBySide ? "editor.side" : "editor.stack",
                           selected: project.layout == layout, segmented: true) {
                    model.edit {
                        $0.layout = layout
                        $0.followsPhotoOrientation = false
                    }
                }
            }
        }
        .padding(4)
        .background(Theme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
        .disabled(model.busy)
    }

    private func tools(_ project: ComparisonProject) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: type.isAccessibilitySize ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: 6) {
            ToolButton(key: "editor.swap", id: "editor.swap") {
                model.swap()
            }
            .disabled(!project.isComplete)
            ToolButton(key: "editor.align", id: "editor.align", selected: alignment) {
                alignment.toggle()
                if project[active] == nil { active = active.opposite }
            }
            ToolButton(key: "editor.labels", id: "editor.labels", selected: project.labels) {
                model.edit { $0.labels.toggle() }
            }
            ToolButton(key: "size.title", id: "editor.size") { model.panel = .sizes }
        }
        .disabled(model.busy)
    }

    private func actions(_ project: ComparisonProject) -> some View {
        VStack(spacing: 6) {
            if model.busy {
                ProgressView(L.t("work.progress"))
                if !model.savingPhoto {
                    TextAction("action.cancel", id: "work.cancel") { model.cancelWork() }
                }
            } else {
                if let message = model.message { InlineMessage(key: message).multilineTextAlignment(.center) }
                if model.fallback != nil {
                    TextAction("export.saveFile", id: "editor.saveFiles") { model.saveFile() }
                }
                if model.saved {
                    Label(L.t("export.saved"), systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.green)
                        .accessibilityIdentifier("editor.saved")
                    PrimaryButton("card.make", id: "editor.makeCard") { model.makeCard() }
                        .disabled(!project.isComplete)
                } else {
                    PrimaryButton("export.savePhotos", id: "editor.save") { model.save() }
                        .disabled(!project.isComplete || (project.output.isAdvanced && !Launch.freePeriod))
                    Text(L.t("export.clean")).font(.footnote).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
    }
}

private struct ToolButton: View {
    let key: String
    let id: String
    var selected = false
    var segmented = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(L.t(key))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 3)
                .foregroundStyle(selected ? Theme.green : Theme.ink)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(segmented && !selected ? .clear : Theme.line) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if segmented { return selected ? Theme.surface : .clear }
        return selected ? Theme.soft : Theme.surface
    }
}

private struct PhotoTile: View {
    let project: ComparisonProject
    let slot: Slot
    let geometry: CollageGeometry
    let scale: CGFloat
    let image: UIImage?
    let aligning: Bool
    let selected: Bool
    let tap: () -> Void
    let adjust: (Pose) -> Void

    @GestureState private var motion = Motion()
    private struct Motion {
        var translation: CGSize = .zero
        var magnification: CGFloat = 1
    }

    var body: some View {
        let area = geometry.imageArea(slot)
        let imageWidth = area.width * scale
        let imageHeight = area.height * scale
        let visual = Button(action: tap) {
            VStack(spacing: 0) {
                ZStack {
                    Theme.tile
                    if let image, let photo = project[slot] {
                        let pose = adjusted(photo.pose, movement: motion)
                        let original = geometry.photo(photo.asset.pixels, pose: pose, slot: slot)
                        let rect = original.offsetBy(dx: -area.minX, dy: -area.minY)
                            .applying(CGAffineTransform(scaleX: scale, y: scale))
                        Image(uiImage: image).resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        if aligning { guides }
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: "plus.circle").font(.title2)
                            Text(L.t(slot == .before ? "photo.addBefore" : "photo.addAfter"))
                                .font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                        }
                        .padding(4)
                        .foregroundStyle(Theme.green)
                    }
                }
                .frame(width: imageWidth, height: imageHeight)
                .clipped()
                if project.labels {
                    Text(L.t(slot.key))
                        .font(.system(size: max(8, geometry.labelFont * scale), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: imageWidth, height: geometry.labelHeight * scale)
                        .foregroundStyle(Theme.green)
                        .background(Color(uiColor: Palette.label(slot)))
                        .clipped()
                }
            }
            .overlay { Rectangle().strokeBorder(selected ? Theme.green : .clear, lineWidth: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t(accessibilityKey))
        .accessibilityIdentifier("editor.slot." + slot.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(L.t("editor.resetPose"))) {
            if selected { adjust(Pose()) }
        }
        .accessibilityAdjustableAction { direction in
            guard selected, let photo = project[slot] else { return }
            var pose = photo.pose
            switch direction {
            case .increment: pose.zoom += 0.2
            case .decrement: pose.zoom -= 0.2
            @unknown default: return
            }
            adjust(pose)
        }

        if selected, let photo = project[slot] {
            visual.simultaneousGesture(
                MagnifyGesture().simultaneously(with: DragGesture(minimumDistance: 4))
                    .updating($motion) { value, state, _ in
                        state = Motion(translation: value.second?.translation ?? state.translation,
                                       magnification: value.first?.magnification ?? state.magnification)
                    }
                    .onEnded { value in
                        let movement = Motion(translation: value.second?.translation ?? motion.translation,
                                              magnification: value.first?.magnification ?? motion.magnification)
                        adjust(adjusted(photo.pose, movement: movement))
                    }
            )
        } else {
            visual
        }
    }

    private var accessibilityKey: String {
        if project[slot] == nil { return slot == .before ? "photo.addBefore" : "photo.addAfter" }
        return slot.key
    }

    private func adjusted(_ original: Pose, movement: Motion) -> Pose {
        let area = geometry.imageArea(slot)
        guard scale > 0, let photo = project[slot] else { return original }
        let pose = Pose(x: original.x + Double(movement.translation.width / (area.width * scale)),
                        y: original.y + Double(movement.translation.height / (area.height * scale)),
                        zoom: original.zoom * Double(movement.magnification))
        return geometry.clamp(pose, pixels: photo.asset.pixels, slot: slot)
    }

    private var guides: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            if selected {
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            context.stroke(path, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
