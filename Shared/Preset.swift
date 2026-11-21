import Foundation
import CoreFoundation

struct PresetV1: Equatable {
    static let limit = 4096
    static let prefix = "BA1-"
    var layout: Layout
    var spacing: Int
    var labels: Bool
    var output: OutputSize

    init(project: ComparisonProject) {
        layout = project.layout
        spacing = project.spacing
        labels = project.labels
        output = project.output
    }

    init(data: Data) throws {
        guard data.count <= Self.limit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.integer(object["version"]) == 1,
              let rawLayout = object["layout"] as? String, let layout = Layout(rawValue: rawLayout),
              let spacing = Self.integer(object["spacing"]), (0...20).contains(spacing),
              let label = object["labels"] as? NSNumber, CFGetTypeID(label) == CFBooleanGetTypeID(),
              let size = object["size"] as? String else { throw PresetError.invalid }
        var fields: Set<String> = ["version", "layout", "spacing", "labels", "size"]
        switch size {
        case "basic": output = .basic
        case "high": output = .high
        case "custom":
            fields.formUnion(["width", "height"])
            guard let width = Self.integer(object["width"]),
                  let height = Self.integer(object["height"]) else { throw PresetError.invalid }
            output = .custom(Pixels(width: width, height: height))
        default: throw PresetError.invalid
        }
        guard Set(object.keys) == fields, output.isValid else { throw PresetError.invalid }
        self.layout = layout
        self.spacing = spacing
        labels = label.boolValue
    }

    init(code: String) throws {
        guard code.utf8.count <= Self.limit else { throw PresetError.invalid }
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix(Self.prefix) else { throw PresetError.invalid }
        let input = String(clean.dropFirst(Self.prefix.count))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)
        guard input.utf8.allSatisfy(allowed.contains) else { throw PresetError.invalid }
        let base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64 + padding) else { throw PresetError.invalid }
        try self.init(data: data)
    }

    var data: Data {
        get throws {
            var object: [String: Any] = ["version": 1, "layout": layout.rawValue, "spacing": spacing, "labels": labels]
            switch output {
            case .basic: object["size"] = "basic"
            case .high: object["size"] = "high"
            case .custom(let pixels):
                object["size"] = "custom"
                object["width"] = pixels.width
                object["height"] = pixels.height
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    var code: String {
        get throws {
            try Self.prefix + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }

    func apply(to project: inout ComparisonProject, useBasic: Bool = false) {
        project.layout = layout
        project.followsPhotoOrientation = false
        project.spacing = spacing
        project.labels = labels
        project.output = useBasic ? .basic : output
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, abs(value) <= 1_000_000, value.rounded() == value else { return nil }
        return Int(value)
    }
}

enum PresetError: Error { case invalid }

struct ReviewHistory: Codable {
    private(set) var days: Set<Date> = []
    private(set) var lastRequest: Date?

    mutating func visit(_ now: Date, calendar: Calendar = .current) {
        days.insert(calendar.startOfDay(for: now))
        if days.count > 3 { days = Set(days.sorted().suffix(3)) }
    }

    func eligible(at now: Date, exports: Int, blocked: Bool) -> Bool {
        !blocked && exports >= 5 && days.count >= 3
            && (lastRequest.map { now.timeIntervalSince($0) >= 180 * 86_400 } ?? true)
    }

    mutating func record(_ now: Date) { lastRequest = now }
}
