import XCTest
import UIKit

final class ProjectStoreTests: XCTestCase {
    func testPartialDraftReloadAndExistingExportRemainAccessible() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let location = folder.appending(path: "store")
        let store = ProjectStore(root: location)
        _ = try await store.prepare()
        var project = ComparisonProject()
        project.before = PlacedPhoto(asset: try await store.importPhoto(source))
        project.touch()
        _ = try await store.upsert(project)

        let restarted = ProjectStore(root: location)
        let partial = try await restarted.prepare()
        XCTAssertEqual(partial.projects.first?.before, project.before)
        XCTAssertNil(partial.projects.first?.after)
        project.after = PlacedPhoto(asset: try await restarted.importPhoto(source))
        project.output = .custom(Pixels(width: 512, height: 600))
        project.touch()
        _ = try await restarted.upsert(project)
        let draft = project
        async let first = restarted.generate(draft)
        async let second = restarted.generate(draft)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.0.id, two.0.id)
        XCTAssertEqual(one.0.pixels, Pixels(width: 512, height: 600))
        XCTAssertEqual(one.2.distinctExports, 1)
        XCTAssertFalse(one.0.savedToPhotos)
        let completed = try await restarted.markPhotosSaved(one.0.id)
        XCTAssertEqual(completed.exports.first?.savedToPhotos, true)

        let (cardURL, withCard) = try await restarted.writeCard(title: "Before & After", project: project, qr: nil, milestone: nil)
        XCTAssertEqual(withCard?.exports.last?.kind, .card)
        XCTAssertEqual(withCard?.exports.last?.pixels, ImagePipeline.cardSize)
        XCTAssertEqual(withCard?.distinctExports, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cardURL.path))

        let basic = project.basicCopy()
        _ = try await restarted.upsert(basic)
        XCTAssertNotEqual(basic.id, project.id)
        XCTAssertEqual(basic.output, .basic)
        let final = try await restarted.current()
        XCTAssertTrue(final.projects.contains { $0.id == project.id && $0.output.isAdvanced })
        let original = try await restarted.newestUsableExport(for: project.id)
        XCTAssertEqual(original.1, one.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.1.path))
    }

    func testInvalidImportAndCleanupOnlyUnreferencedFiles() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let location = folder.appending(path: "store")
        let store = ProjectStore(root: location)
        _ = try await store.prepare()
        let bad = folder.appending(path: "broken")
        try Data([0, 1, 2]).write(to: bad)
        do {
            _ = try await store.importPhoto(bad)
            XCTFail("A corrupt source should fail.")
        } catch {}
        let valid = try await store.importPhoto(source)
        let orphan = try await store.importPhoto(source)
        var project = ComparisonProject()
        project.before = PlacedPhoto(asset: valid)
        _ = try await store.upsert(project)
        let refreshed = ProjectStore(root: location)
        _ = try await refreshed.prepare()
        let photos = location.appending(path: "photos")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photos.appending(path: valid.source).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: photos.appending(path: orphan.source).path))

        let escaped = ExportRecord(id: UUID(), projectID: project.id, revision: 0,
                                   path: "../" + valid.source, pixels: project.pixels, createdAt: Date())
        do {
            _ = try await refreshed.exportURL(escaped)
            XCTFail("A noncanonical export path should fail.")
        } catch {}
    }

    func testMilestoneCountsDistinctProjectsAndAcknowledges() throws {
        var index = ProjectIndex()
        let shared = UUID()
        for id in [shared, shared, UUID()] {
            index.exports.append(ExportRecord(id: UUID(), projectID: id, revision: 0, path: "test",
                                              pixels: Pixels(width: 512, height: 512), createdAt: Date()))
        }
        XCTAssertEqual(index.distinctExports, 2)
        XCTAssertNil(index.milestone)
        index.exports.append(ExportRecord(id: UUID(), projectID: UUID(), revision: 0, path: "test",
                                          pixels: Pixels(width: 512, height: 512), createdAt: Date()))
        XCTAssertEqual(index.milestone, 3)
    }

    func testCancelledExportDoesNotCommitHistory() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(in: folder)
        let store = ProjectStore(root: folder.appending(path: "store"))
        _ = try await store.prepare()
        let asset = try await store.importPhoto(source)
        var project = ComparisonProject()
        project.before = PlacedPhoto(asset: asset)
        project.after = PlacedPhoto(asset: asset)
        _ = try await store.upsert(project)
        let draft = project
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.generate(draft)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled request should not generate an export.")
        } catch is CancellationError {}
        let index = try await store.current()
        XCTAssertTrue(index.exports.isEmpty)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(in folder: URL) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 140, height: 100)).image { ctx in
            UIColor(red: 0.2, green: 0.5, blue: 0.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 140, height: 100))
        }
        let url = folder.appending(path: "fixture.jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.85)).write(to: url)
        return url
    }
}
