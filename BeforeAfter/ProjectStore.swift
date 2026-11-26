import Foundation
import UIKit
import ImageIO

actor ProjectStore {
    private enum Folder: String, CaseIterable { case photos, thumbnails, exports, transfers }
    private let root: URL
    private let fm = FileManager.default
    private var state: ProjectIndex?

    init(root: URL) { self.root = root }

    static func defaultRoot(testing: Bool) -> URL {
        URL.applicationSupportDirectory.appending(path: testing ? "BeforeAfterUITests" : "BeforeAfter", directoryHint: .isDirectory)
    }

    func prepare(reset: Bool = false) throws -> ProjectIndex {
        if reset, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        for folder in Folder.allCases {
            try fm.createDirectory(at: root.appending(path: folder.rawValue, directoryHint: .isDirectory),
                                   withIntermediateDirectories: true)
        }
        var resourceRoot = root
        try? resourceRoot.setResourceValues(URLResourceValues.excludedFromBackup)
        let index = root.appending(path: "index.json")
        if fm.fileExists(atPath: index.path) {
            state = try JSONDecoder().decode(ProjectIndex.self, from: Data(contentsOf: index))
        } else {
            state = ProjectIndex()
        }
        try cleanup()
        return try current()
    }

    func current() throws -> ProjectIndex {
        guard let state else { throw CollageError.writeFailed }
        return state
    }

    func upsert(_ project: ComparisonProject) throws -> ProjectIndex {
        var index = try current()
        if let position = index.projects.firstIndex(where: { $0.id == project.id }) {
            let saved = index.projects[position]
            guard saved.revision <= project.revision else { return index }
            var updated = project
            if updated.lastExportID == nil { updated.lastExportID = saved.lastExportID }
            index.projects[position] = updated
        } else {
            index.projects.append(project)
        }
        try commit(index)
        return index
    }

    func importPhoto(_ incoming: URL) throws -> PhotoAsset {
        try Task.checkCancellation()
        let id = UUID()
        let sourcePath = id.uuidString + ".original"
        let thumbnailPath = id.uuidString + ".jpg"
        let original = root.appending(path: "photos").appending(path: sourcePath)
        let thumb = root.appending(path: "thumbnails").appending(path: thumbnailPath)
        do {
            let sourceSize = try incoming.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try requireSpace(Int64(sourceSize) + 4_000_000)
            try fm.copyItem(at: incoming, to: original)
            let source = try ImagePipeline.source(original)
            let (pixels, format) = try ImagePipeline.metadata(source)
            let image = try ImagePipeline.thumbnail(source, maxEdge: 980)
            try ImagePipeline.jpeg(image, quality: 0.88).write(to: thumb, options: .atomic)
            try Task.checkCancellation()
            return PhotoAsset(id: id, source: sourcePath, thumbnail: thumbnailPath, pixels: pixels, format: format)
        } catch {
            try? fm.removeItem(at: original)
            try? fm.removeItem(at: thumb)
            throw error
        }
    }

    func thumbnails(_ project: ComparisonProject) -> [Slot: UIImage] {
        var result: [Slot: UIImage] = [:]
        for slot in Slot.allCases {
            guard let asset = project[slot]?.asset,
                  let thumb = try? file(asset.thumbnail, folder: .thumbnails, ext: "jpg") else { continue }
            if let cached = try? ImagePipeline.source(thumb),
               let image = try? ImagePipeline.thumbnail(cached, maxEdge: 980) {
                result[slot] = UIImage(cgImage: image)
            } else if let source = try? original(asset),
                      let image = try? ImagePipeline.thumbnail(source, maxEdge: 980) {
                if let data = try? ImagePipeline.jpeg(image, quality: 0.88) {
                    try? data.write(to: thumb, options: .atomic)
                }
                result[slot] = UIImage(cgImage: image)
            }
        }
        return result
    }

    func generate(_ project: ComparisonProject) throws -> (ExportRecord, URL, ProjectIndex) {
        guard project.isComplete, project.output.isValid else { throw CollageError.invalidSize }
        try Task.checkCancellation()
        let index = try current()
        if let record = index.exports.last(where: { $0.projectID == project.id && $0.revision == project.revision && $0.isCollage }),
           let url = try? exportURL(record) {
            return (record, url, index)
        }
        try requireSpace(Int64(project.pixels.width * project.pixels.height * 4) + 4_000_000)
        let images = try originals(project, maximum: max(project.pixels.width, project.pixels.height))
        try Task.checkCancellation()
        let image = try ImagePipeline.render(project, images: images)
        let data = try ImagePipeline.jpeg(image, quality: 0.93)
        try Task.checkCancellation()
        let id = UUID()
        let record = ExportRecord(id: id, projectID: project.id, revision: project.revision,
                                  path: id.uuidString + ".jpg", pixels: project.pixels, createdAt: Date())
        let (url, updated) = try writeExport(data, record: record, project: project)
        return (record, url, updated)
    }

    private func writeExport(_ data: Data, record: ExportRecord, project: ComparisonProject) throws -> (URL, ProjectIndex) {
        var index = try current()
        let url = try file(record.path, folder: .exports, ext: "jpg")
        try data.write(to: url, options: .atomic)
        do {
            var updated = project
            updated.lastExportID = record.id
            if let position = index.projects.firstIndex(where: { $0.id == project.id }) {
                guard index.projects[position].revision == project.revision else { throw CollageError.writeFailed }
                index.projects[position] = updated
            } else {
                index.projects.append(updated)
            }
            index.exports.append(record)
            try commit(index)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return (url, index)
    }

    func newestUsableExport(for id: UUID) throws -> (ExportRecord, URL) {
        let index = try current()
        for record in index.exports.reversed() where record.projectID == id && record.isCollage {
            if let url = try? exportURL(record) { return (record, url) }
        }
        throw CollageError.missingFile
    }

    func exportURL(_ record: ExportRecord) throws -> URL {
        let url = try file(record.path, folder: .exports, ext: "jpg")
        guard fm.fileExists(atPath: url.path) else { throw CollageError.missingFile }
        return url
    }

    @discardableResult
    func markPhotosSaved(_ id: UUID) throws -> ProjectIndex {
        var index = try current()
        if let position = index.exports.firstIndex(where: { $0.id == id }) {
            index.exports[position].savedToPhotos = true
            try commit(index)
        }
        return index
    }

    func acknowledgeMilestone(_ count: Int) throws -> ProjectIndex {
        var index = try current()
        index.savedMilestone = max(count, index.savedMilestone ?? 0)
        try commit(index)
        return index
    }

    func renderCardPreview(title: String, project: ComparisonProject?, qr: URL?, placeholder: Bool,
                           milestone: Int?) throws -> UIImage {
        let content = CardContent(title: title, project: project, images: project.map(thumbnails) ?? [:],
                                  downloadCode: qr.flatMap(ImagePipeline.qr),
                                  showPlaceholder: placeholder, milestone: milestone)
        return UIImage(cgImage: try ImagePipeline.card(content))
    }

    func writeCard(title: String, project: ComparisonProject?, qr: URL?, milestone: Int?) throws -> (URL, ProjectIndex?) {
        try Task.checkCancellation()
        try requireSpace(12_000_000)
        let images: [Slot: UIImage]
        if let project {
            images = try originals(project, maximum: 1350)
        } else {
            images = [:]
        }
        let content = CardContent(title: title, project: project, images: images, downloadCode: qr.flatMap(ImagePipeline.qr),
                                  showPlaceholder: false, milestone: milestone)
        let image = try ImagePipeline.card(content)
        try Task.checkCancellation()
        let data = try ImagePipeline.jpeg(image, quality: 0.94)
        if let project, milestone == nil {
            let id = UUID()
            let record = ExportRecord(id: id, projectID: project.id, revision: project.revision,
                                      path: id.uuidString + ".jpg", pixels: ImagePipeline.cardSize,
                                      createdAt: Date(), kind: .card)
            let (url, index) = try writeExport(data, record: record, project: project)
            return (url, index)
        }
        return (try transfer(data, ext: "jpg"), nil)
    }

    func writePreset(_ preset: PresetV1) throws -> URL { try transfer(preset.data, ext: "bapreset") }

    func readPreset(_ url: URL) throws -> PresetV1 {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "bapreset" else { throw PresetError.invalid }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: PresetV1.limit + 1) ?? Data()
        return try PresetV1(data: data)
    }

    private func transfer(_ data: Data, ext: String) throws -> URL {
        let url = try file(UUID().uuidString + "." + ext, folder: .transfers, ext: ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func original(_ asset: PhotoAsset) throws -> CGImageSource {
        try ImagePipeline.source(file(asset.source, folder: .photos, ext: "original"))
    }

    private func originals(_ project: ComparisonProject, maximum: Int) throws -> [Slot: UIImage] {
        var result: [Slot: UIImage] = [:]
        let geometry = CollageGeometry(project: project)
        let outputScale = min(1, CGFloat(maximum) / max(geometry.size.width, geometry.size.height))
        for slot in Slot.allCases {
            try Task.checkCancellation()
            guard let photo = project[slot] else { throw CollageError.missingFile }
            let target = geometry.photo(photo.asset.pixels, pose: photo.pose, slot: slot)
            let needed = max(target.width, target.height) * outputScale
            let decodeEdge = Int(min(CGFloat(4096), max(1, needed.rounded(.up))))
            let source = try original(photo.asset)
            result[slot] = UIImage(cgImage: try ImagePipeline.thumbnail(source, maxEdge: decodeEdge))
        }
        return result
    }

    private func file(_ name: String, folder: Folder, ext: String) throws -> URL {
        guard name.hasSuffix("." + ext),
              let id = UUID(uuidString: String(name.dropLast(ext.count + 1))),
              name == id.uuidString + "." + ext else { throw CollageError.missingFile }
        return root.appending(path: folder.rawValue).appending(path: name)
    }

    private func commit(_ index: ProjectIndex) throws {
        try JSONEncoder().encode(index).write(to: root.appending(path: "index.json"), options: .atomic)
        state = index
    }

    private func requireSpace(_ bytes: Int64) throws {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw CollageError.lowSpace
        }
    }

    private func cleanup() throws {
        let index = try current()
        let assets = index.projects.flatMap { [$0.before?.asset, $0.after?.asset].compactMap { $0 } }
        prune(.photos, keeping: Set(assets.map(\.source)), ext: "original")
        prune(.thumbnails, keeping: Set(assets.map(\.thumbnail)), ext: "jpg")
        prune(.exports, keeping: Set(index.exports.map(\.path)), ext: "jpg")
        prune(.transfers, keeping: [], ext: "jpg")
        prune(.transfers, keeping: [], ext: "bapreset")
    }

    private func prune(_ folder: Folder, keeping paths: Set<String>, ext: String) {
        let dir = root.appending(path: folder.rawValue)
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if !paths.contains(name), (try? file(name, folder: folder, ext: ext)) != nil {
                try? fm.removeItem(at: url)
            }
        }
    }
}

private extension URLResourceValues {
    static var excludedFromBackup: Self {
        var values = Self()
        values.isExcludedFromBackup = true
        return values
    }
}
