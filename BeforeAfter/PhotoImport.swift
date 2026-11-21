import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import Photos

struct IncomingPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: "ba-" + UUID().uuidString)
            let opened = received.file.startAccessingSecurityScopedResource()
            defer { if opened { received.file.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return IncomingPhoto(url: copy)
        }
    }
}

enum PhotoLibrary {
    static func save(_ url: URL) async throws {
        var permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if permission == .notDetermined {
            permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard permission == .authorized || permission == .limited else { throw CollageError.photoDenied }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

extension UTType {
    static let beforeAfterPreset = UTType(exportedAs: "com.hgsldswk.beforeafter.preset", conformingTo: .json)
}
