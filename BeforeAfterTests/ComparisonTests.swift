import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreImage

final class ComparisonTests: XCTestCase {
    func testAutomaticLayoutsAndFixedBasicDimensions() {
        let portrait = Pixels(width: 600, height: 800)
        let landscape = Pixels(width: 800, height: 600)
        XCTAssertEqual(Layout.automatic(portrait, portrait), .sideBySide)
        XCTAssertEqual(Layout.automatic(landscape, landscape), .stacked)
        XCTAssertEqual(Layout.automatic(landscape, portrait), .sideBySide)
        XCTAssertEqual(OutputSize.basic.pixels(for: .sideBySide), Pixels(width: 2048, height: 1365))
        XCTAssertEqual(OutputSize.basic.pixels(for: .stacked), Pixels(width: 1365, height: 2048))
        XCTAssertEqual(OutputSize.high.pixels(for: .stacked), Pixels(width: 2731, height: 4096))
        XCTAssertTrue(Pixels(width: 4096, height: 4096).validCustom)
        XCTAssertFalse(Pixels(width: 4097, height: 4096).validCustom)
        XCTAssertFalse(Pixels(width: Int.max, height: Int.max).validCustom)
    }

    func testContainmentLabelsPoseBoundsAndSwap() {
        var project = ComparisonProject()
        let tall = asset(width: 30, height: 30000)
        let flat = asset(width: 30000, height: 30)
        project.before = PlacedPhoto(asset: tall)
        project.after = PlacedPhoto(asset: flat, pose: Pose(x: 0.1, y: 0.05, zoom: 2))
        let geometry = CollageGeometry(project: project)
        let area = geometry.imageArea(.before)
        let fitted = geometry.photo(tall.pixels, pose: Pose(), slot: .before)
        XCTAssertTrue(area.insetBy(dx: -0.01, dy: -0.01).contains(fitted))
        XCTAssertEqual(fitted.midX, area.midX, accuracy: 0.01)
        XCTAssertEqual(fitted.height, area.height, accuracy: 0.01)
        XCTAssertEqual(geometry.label(.before).minY, area.maxY)
        XCTAssertLessThan(geometry.tile(.before).maxX, geometry.tile(.after).minX)
        let clamped = geometry.clamp(Pose(x: 9, y: -.infinity, zoom: 80), pixels: tall.pixels, slot: .before)
        XCTAssertLessThan(clamped.x, 0.5)
        XCTAssertEqual(clamped.y, 0)
        XCTAssertEqual(clamped.zoom, 4)
        project.swapPhotos()
        XCTAssertEqual(project.before?.asset.id, flat.id)
        XCTAssertEqual(project.before?.pose.zoom, 2)
        XCTAssertEqual(project.after?.asset.id, tall.id)
        project.labels = false
        XCTAssertEqual(CollageGeometry(project: project).imageArea(.before), geometry.tile(.before))
    }

    func testGeometryAndJPEGKeepLabelsOutsideImagesAndDiscardMetadata() throws {
        var project = ComparisonProject()
        project.output = .custom(Pixels(width: 512, height: 512))
        project.before = PlacedPhoto(asset: asset(width: 60, height: 50))
        project.after = PlacedPhoto(asset: asset(width: 60, height: 50))
        let red = try XCTUnwrap(solid(.red).cgImage)
        let blue = solid(.blue)
        let captureDate = "2001:02:03 04:05:06"
        let cameraModel = "BeforeAfter Test Camera"
        let taggedSource = try jpegSource(red, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.25, kCGImagePropertyGPSLongitudeRef: "E"
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: captureDate],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: cameraModel]
        ])
        let originalProperties = try jpegProperties(taggedSource)
        let originalGPS = try XCTUnwrap(originalProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        let originalExif = try XCTUnwrap(originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let originalTIFF = try XCTUnwrap(originalProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(originalGPS[kCGImagePropertyGPSLatitude] as? Double, 12.5)
        XCTAssertEqual(originalExif[kCGImagePropertyExifDateTimeOriginal] as? String, captureDate)
        XCTAssertEqual(originalTIFF[kCGImagePropertyTIFFModel] as? String, cameraModel)

        let taggedPhoto = UIImage(cgImage: try ImagePipeline.thumbnail(taggedSource, maxEdge: 512))
        let image = try ImagePipeline.render(project, images: [.before: taggedPhoto, .after: blue])
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(image.colorSpace?.name.map { $0 as String }, CGColorSpace.sRGB as String)

        let jpeg = try ImagePipeline.jpeg(image, quality: 0.95)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try jpegProperties(source)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyExifAuxDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])

        let cleanSource = try jpegSource(red, properties: [:])
        let cleanPhoto = UIImage(cgImage: try ImagePipeline.thumbnail(cleanSource, maxEdge: 512))
        let cleanImage = try ImagePipeline.render(project, images: [.before: cleanPhoto, .after: blue])
        let referenceSource = try jpegSource(cleanImage, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let reference = try jpegProperties(referenceSource)
        for group in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary] {
            guard let entries = properties[group] else { continue }
            let actual = try XCTUnwrap(entries as? [String: NSObject])
            let encoderDefaults = reference[group] as? [String: NSObject] ?? [:]
            let unexpected = actual.keys.filter { actual[$0] != encoderDefaults[$0] }.sorted()
            XCTAssertTrue(unexpected.isEmpty, "Unexpected JPEG metadata in \(group): \(unexpected)")
        }

        let geometry = CollageGeometry(project: project)
        let before = geometry.imageArea(.before)
        let after = geometry.imageArea(.after)
        let left = try rgba(image, x: Int(before.midX), y: Int(before.midY))
        let right = try rgba(image, x: Int(after.midX), y: Int(after.midY))
        XCTAssertGreaterThan(left[0], left[2])
        XCTAssertGreaterThan(right[2], right[0])
        let label = try rgba(image, x: 8, y: Int(geometry.label(.before).midY))
        XCTAssertGreaterThan(label[1], 200)
    }

    func testImageIOHandlesRotatedAndMirroredOrientation() throws {
        let image = try XCTUnwrap(solid(.red).cgImage)
        for orientation in [2, 5, 6, 7, 8] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let (size, _) = try ImagePipeline.metadata(source)
            XCTAssertEqual(size, orientation >= 5 ? Pixels(width: 50, height: 60) : Pixels(width: 60, height: 50))
            let oriented = try ImagePipeline.thumbnail(source, maxEdge: 60)
            XCTAssertEqual(oriented.width, size.width)
            XCTAssertEqual(oriented.height, size.height)
        }
    }

    func testCardDownloadCodeCanBeDecodedFromResult() throws {
        let url = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id1234567890"))
        let code = try XCTUnwrap(ImagePipeline.qr(url))
        let image = try ImagePipeline.card(CardContent(title: "Before and after", project: nil,
                                                       images: [:], downloadCode: code,
                                                       showPlaceholder: false, milestone: 3))
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1350)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(features, [url.absoluteString])
    }

    func testPresetRoundTripAndStrictValidation() throws {
        var project = ComparisonProject()
        project.title = "Private title"
        project.before = PlacedPhoto(asset: asset(width: 200, height: 100))
        project.layout = .stacked
        project.labels = false
        project.output = .custom(Pixels(width: 2400, height: 3000))
        let preset = PresetV1(project: project)
        XCTAssertEqual(try PresetV1(code: "  " + preset.code + "\n"), preset)
        XCTAssertEqual(try PresetV1(data: preset.data), preset)
        let encoded = try XCTUnwrap(String(data: preset.data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("Private"))
        XCTAssertFalse(encoded.contains("thumbnail"))
        XCTAssertThrowsError(try PresetV1(code: "BA1-?bad"))
        XCTAssertThrowsError(try PresetV1(data: Data(repeating: 0, count: 4097)))
        for (old, new) in [("\"version\":1", "\"version\":2"), ("\"labels\":false", "\"labels\":0"),
                           ("\"spacing\":6", "\"spacing\":true"), ("\"width\":2400", "\"width\":4097"),
                           ("\"spacing\":6", "\"spacing\":6,\"title\":\"hidden\"")] {
            XCTAssertThrowsError(try PresetV1(data: Data(encoded.replacingOccurrences(of: old, with: new).utf8)))
        }
        var copy = ComparisonProject()
        preset.apply(to: &copy, useBasic: true)
        XCTAssertEqual(copy.layout, .stacked)
        XCTAssertFalse(copy.followsPhotoOrientation)
        XCTAssertEqual(copy.output, .basic)
        XCTAssertEqual(preset.output, project.output)
    }

    func testEntitlementExpiryReceiptAndOneTimeUnlock() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var plan = Entitlement(firstOpen: start)
        XCTAssertTrue(plan.hasPro(at: start, free: false))
        XCTAssertTrue(plan.hasPro(at: start + 30 * 86_400 - 1, free: false))
        XCTAssertFalse(plan.hasPro(at: start + 30 * 86_400, free: false))
        XCTAssertTrue(plan.hasPro(at: start + 400 * 86_400, free: true))
        XCTAssertEqual(plan.remainingDays(at: start + 1), 30)
        let paidStart = start + 90 * 86_400
        plan.beginPaidMode(at: paidStart)
        plan.beginPaidMode(at: paidStart + 86_400)
        XCTAssertEqual(plan.trialStart, paidStart)
        plan.recordTrial(at: paidStart + 19 * 86_400)
        XCTAssertEqual(plan.trialStart, paidStart)
        let restoredReceipt = paidStart - 21 * 86_400
        plan.recordTrial(at: restoredReceipt)
        XCTAssertEqual(plan.trialStart, restoredReceipt)
        XCTAssertFalse(plan.hasPro(at: paidStart + 10 * 86_400, free: false))
        plan.purchasedPro = true
        XCTAssertTrue(plan.hasPro(at: start + 800 * 86_400, free: false))
    }

    func testReviewThresholdAndCooldown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        var review = ReviewHistory()
        review.visit(day, calendar: calendar)
        review.visit(day + 1, calendar: calendar)
        review.visit(day + 86_400, calendar: calendar)
        XCTAssertFalse(review.eligible(at: day + 86_400, exports: 5, blocked: false))
        let request = day + 2 * 86_400
        review.visit(request, calendar: calendar)
        XCTAssertFalse(review.eligible(at: request, exports: 4, blocked: false))
        XCTAssertFalse(review.eligible(at: request, exports: 5, blocked: true))
        XCTAssertTrue(review.eligible(at: request, exports: 5, blocked: false))
        review.record(request)
        XCTAssertFalse(review.eligible(at: request + 180 * 86_400 - 1, exports: 5, blocked: false))
        XCTAssertTrue(review.eligible(at: request + 180 * 86_400, exports: 5, blocked: false))
    }

    func testIndexMigrationAndUnsupportedVersion() throws {
        let index = try JSONDecoder().decode(ProjectIndex.self, from: Data("{}".utf8))
        XCTAssertEqual(index.version, 1)
        XCTAssertTrue(index.projects.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectIndex.self, from: Data("{\"version\":23}".utf8)))
    }

    private func asset(width: Int, height: Int) -> PhotoAsset {
        PhotoAsset(id: UUID(), source: "original", thumbnail: "preview",
                   pixels: Pixels(width: width, height: height), format: "public.jpeg")
    }

    private func solid(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 50), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 50))
        }
    }

    private func jpegSource(_ image: CGImage, properties: [CFString: Any]) throws -> CGImageSource {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private func jpegProperties(_ source: CGImageSource) throws -> [CFString: Any] {
        try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { pointer in
            let ctx = try XCTUnwrap(CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
