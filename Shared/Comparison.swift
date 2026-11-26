import Foundation
import CoreGraphics

enum Layout: String, Codable, CaseIterable, Hashable {
    case sideBySide, stacked
    var key: String { self == .sideBySide ? "layout.side" : "layout.stack" }

    static func automatic(_ first: Pixels, _ second: Pixels) -> Self {
        first.width > first.height && second.width > second.height ? .stacked : .sideBySide
    }
}

enum Slot: String, Codable, CaseIterable, Hashable {
    case before, after
    var key: String { "slot." + rawValue }
    var opposite: Self { self == .before ? .after : .before }
}

struct Pixels: Codable, Equatable {
    let width: Int
    let height: Int

    var size: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
    var text: String { L.f("size.pixels", width, height) }

    var validCustom: Bool {
        (512...4096).contains(width) && (512...4096).contains(height) && width * height <= 16_777_216
    }
}

enum OutputSize: Codable, Equatable {
    case basic, high, custom(Pixels)

    var isAdvanced: Bool { self != .basic }

    var isValid: Bool {
        if case let .custom(pixels) = self { return pixels.validCustom }
        return true
    }

    func pixels(for layout: Layout) -> Pixels {
        if case let .custom(pixels) = self, pixels.validCustom { return pixels }
        let edge = self == .high ? 4096 : 2048
        let short = (edge * 2 + 1) / 3
        return layout == .sideBySide ? Pixels(width: edge, height: short) : Pixels(width: short, height: edge)
    }
}

struct Pose: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var zoom: Double = 1
}

struct PhotoAsset: Codable, Equatable, Identifiable {
    let id: UUID
    let source: String
    let thumbnail: String
    let pixels: Pixels
    let format: String
}

struct PlacedPhoto: Codable, Equatable {
    var asset: PhotoAsset
    var pose = Pose()
}

struct ComparisonProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var before: PlacedPhoto?
    var after: PlacedPhoto?
    var layout: Layout = .sideBySide
    var followsPhotoOrientation = true
    var labels = true
    var spacing = 6
    var title: String?
    var output: OutputSize = .basic
    var revision = 0
    var modified = Date()
    var lastExportID: UUID?

    var isComplete: Bool { before != nil && after != nil }
    var pixels: Pixels { output.pixels(for: layout) }

    subscript(_ slot: Slot) -> PlacedPhoto? {
        get { slot == .before ? before : after }
        set { if slot == .before { before = newValue } else { after = newValue } }
    }

    mutating func applyAutomaticLayout() {
        if followsPhotoOrientation, let before, let after {
            layout = Layout.automatic(before.asset.pixels, after.asset.pixels)
        }
        clampPoses()
    }

    mutating func swapPhotos() {
        (before, after) = (after, before)
    }

    mutating func clampPoses() {
        let geometry = CollageGeometry(project: self)
        for slot in Slot.allCases {
            guard var photo = self[slot] else { continue }
            photo.pose = geometry.clamp(photo.pose, pixels: photo.asset.pixels, slot: slot)
            self[slot] = photo
        }
    }

    mutating func touch(at date: Date = Date()) {
        revision += 1
        modified = date
    }

    func basicCopy(at date: Date = Date()) -> Self {
        var copy = self
        copy.id = UUID()
        copy.lastExportID = nil
        copy.output = .basic
        copy.revision = 0
        copy.modified = date
        copy.clampPoses()
        return copy
    }
}

enum ExportKind: String, Codable, Equatable {
    case collage, card
}

struct ExportRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let projectID: UUID
    let revision: Int
    let path: String
    let pixels: Pixels
    let createdAt: Date
    var savedToPhotos = false
    var kind: ExportKind? = nil

    var isCollage: Bool { kind != .card }
}

struct ProjectIndex: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var projects: [ComparisonProject] = []
    var exports: [ExportRecord] = []
    var savedMilestone: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let oldVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard (0...Self.currentVersion).contains(oldVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Index version")
        }
        projects = try values.decodeIfPresent([ComparisonProject].self, forKey: .projects) ?? []
        exports = try values.decodeIfPresent([ExportRecord].self, forKey: .exports) ?? []
        savedMilestone = try values.decodeIfPresent(Int.self, forKey: .savedMilestone)
    }

    var distinctExports: Int { Set(exports.map(\.projectID)).count }
    var milestone: Int? { [3, 10, 25].last { $0 <= distinctExports } }
}

struct CollageGeometry {
    let size: CGSize
    let bounds: CGRect
    private let layout: Layout
    private let gap: CGFloat
    let labelHeight: CGFloat
    let labelFont: CGFloat

    init(project: ComparisonProject, size: CGSize? = nil) {
        self.size = size ?? project.pixels.size
        bounds = CGRect(origin: .zero, size: self.size)
        layout = project.layout
        let short = min(self.size.width, self.size.height)
        gap = (short * CGFloat(project.spacing) / 320).rounded()
        labelHeight = project.labels ? (short * 0.083).rounded() : 0
        labelFont = (short * 0.036).rounded()
    }

    func tile(_ slot: Slot) -> CGRect {
        let horizontal = layout == .sideBySide
        let axis = horizontal ? size.width : size.height
        let first = ((axis - gap) / 2).rounded(.down)
        let start = slot == .before ? 0 : first + gap
        let length = slot == .before ? first : axis - start
        return horizontal ? CGRect(x: start, y: 0, width: length, height: size.height)
            : CGRect(x: 0, y: start, width: size.width, height: length)
    }

    func imageArea(_ slot: Slot) -> CGRect {
        var rect = tile(slot)
        rect.size.height -= labelHeight
        return rect
    }

    func label(_ slot: Slot) -> CGRect {
        let area = imageArea(slot)
        return CGRect(x: area.minX, y: area.maxY, width: area.width, height: labelHeight)
    }

    func clamp(_ pose: Pose, pixels: Pixels, slot: Slot) -> Pose {
        let area = imageArea(slot)
        let zoom = min(4, max(1, pose.zoom.isFinite ? pose.zoom : 1))
        let scaled = fitted(pixels, in: area, zoom: CGFloat(zoom))
        let xLimit = Double(max(0, abs(scaled.width - area.width) / 2) / area.width)
        let yLimit = Double(max(0, abs(scaled.height - area.height) / 2) / area.height)
        return Pose(x: min(xLimit, max(-xLimit, pose.x.isFinite ? pose.x : 0)),
                    y: min(yLimit, max(-yLimit, pose.y.isFinite ? pose.y : 0)), zoom: zoom)
    }

    func fitted(_ pixels: Pixels, in area: CGRect, zoom: CGFloat = 1) -> CGSize {
        let original = pixels.size
        let scale = min(area.width / original.width, area.height / original.height) * zoom
        return CGSize(width: original.width * scale, height: original.height * scale)
    }

    func photo(_ pixels: Pixels, pose: Pose, slot: Slot) -> CGRect {
        let area = imageArea(slot)
        let pose = clamp(pose, pixels: pixels, slot: slot)
        let fitted = fitted(pixels, in: area, zoom: CGFloat(pose.zoom))
        return CGRect(x: area.midX - fitted.width / 2 + area.width * CGFloat(pose.x),
                      y: area.midY - fitted.height / 2 + area.height * CGFloat(pose.y),
                      width: fitted.width, height: fitted.height)
    }
}
