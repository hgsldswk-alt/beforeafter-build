import UIKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum CollageError: Error {
    case unreadablePhoto, missingFile, invalidSize, lowSpace, photoDenied, writeFailed
}

struct CardContent {
    let title: String
    let project: ComparisonProject?
    let images: [Slot: UIImage]
    let downloadCode: UIImage?
    let showPlaceholder: Bool
    let milestone: Int?
}

enum Palette {
    static let paper = UIColor(red: 250/255, green: 249/255, blue: 245/255, alpha: 1)
    static let surface = UIColor(red: 1, green: 254/255, blue: 250/255, alpha: 1)
    static let ink = UIColor(red: 32/255, green: 39/255, blue: 32/255, alpha: 1)
    static let green = UIColor(red: 28/255, green: 90/255, blue: 72/255, alpha: 1)
    static let soft = UIColor(red: 229/255, green: 238/255, blue: 232/255, alpha: 1)
    static let tile = UIColor(red: 238/255, green: 234/255, blue: 226/255, alpha: 1)
    static let line = UIColor(red: 224/255, green: 226/255, blue: 217/255, alpha: 1)
    static let muted = UIColor(red: 92/255, green: 101/255, blue: 94/255, alpha: 1)

    static func label(_ slot: Slot) -> UIColor { slot == .after ? soft : paper }
}

enum ImagePipeline {
    static let cardSize = Pixels(width: 1080, height: 1350)

    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw CollageError.unreadablePhoto }
        return source
    }

    static func metadata(_ source: CGImageSource) throws -> (Pixels, String) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw CollageError.unreadablePhoto }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let dimensions = (5...8).contains(orientation) ? Pixels(width: height, height: width)
            : Pixels(width: width, height: height)
        let format = CGImageSourceGetType(source).map { $0 as String } ?? UTType.image.identifier
        return (dimensions, format)
    }

    static func thumbnail(_ source: CGImageSource, maxEdge: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxEdge)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw CollageError.unreadablePhoto }
        return image
    }

    static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CollageError.writeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CollageError.writeFailed }
        return data as Data
    }

    static func render(_ project: ComparisonProject, images: [Slot: UIImage]) throws -> CGImage {
        guard project.isComplete, project.output.isValid else { throw CollageError.invalidSize }
        return try bitmap(project.pixels) { ctx in
            draw(project, images: images, geometry: CollageGeometry(project: project), in: ctx)
        }
    }

    static func qr(_ url: URL) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let enlarged = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let pixels = CIContext().createCGImage(enlarged, from: enlarged.extent) else { return nil }
        return UIImage(cgImage: pixels)
    }

    static func card(_ content: CardContent) throws -> CGImage {
        try bitmap(cardSize) { ctx in
            fill(CGRect(origin: .zero, size: cardSize.size), color: Palette.surface, in: ctx)
            let headline = CGRect(x: 54, y: 52, width: 972, height: 142)
            drawText(content.title, in: headline, size: 69, color: Palette.ink, alignment: .left, lines: 2)
            if let project = content.project {
                let original = project.pixels.size
                let factor = min(972 / original.width, 846 / original.height)
                let adjusted = CGSize(width: original.width * factor, height: original.height * factor)
                ctx.saveGState()
                ctx.translateBy(x: (1080 - adjusted.width) / 2, y: 214 + (846 - adjusted.height) / 2)
                ctx.scaleBy(x: factor, y: factor)
                draw(project, images: content.images, geometry: CollageGeometry(project: project), in: ctx)
                ctx.restoreGState()
            } else if let milestone = content.milestone {
                drawText(milestone.formatted(), in: CGRect(x: 54, y: 265, width: 972, height: 665),
                         size: 330, color: Palette.green)
            }
            if content.downloadCode != nil || content.showPlaceholder {
                fill(CGRect(x: 54, y: 1110, width: 972, height: 2), color: Palette.line, in: ctx)
                drawText(L.t("card.credit"), in: CGRect(x: 54, y: 1140, width: 710, height: 61),
                         size: 43, color: Palette.green, alignment: .left)
                drawText(L.t("app.name"), in: CGRect(x: 54, y: 1210, width: 710, height: 52),
                         size: 33, color: Palette.muted, alignment: .left)
                let qrRect = CGRect(x: 840, y: 1136, width: 180, height: 180)
                fill(qrRect, color: .white, in: ctx)
                if let code = content.downloadCode {
                    ctx.saveGState()
                    ctx.interpolationQuality = .none
                    code.draw(in: qrRect.insetBy(dx: 15, dy: 15))
                    ctx.restoreGState()
                } else {
                    drawText(L.t("card.placeholder"), in: qrRect.insetBy(dx: 12, dy: 12),
                             size: 24, color: Palette.muted, lines: 3)
                }
            }
        }
    }

    private static func bitmap(_ pixels: Pixels, draw: (CGContext) -> Void) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CollageError.writeFailed }
        ctx.translateBy(x: 0, y: CGFloat(pixels.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        UIGraphicsPushContext(ctx)
        draw(ctx)
        UIGraphicsPopContext()
        guard let image = ctx.makeImage() else { throw CollageError.writeFailed }
        return image
    }

    private static func draw(_ project: ComparisonProject, images: [Slot: UIImage],
                             geometry: CollageGeometry, in ctx: CGContext) {
        fill(geometry.bounds, color: Palette.surface, in: ctx)
        for slot in Slot.allCases {
            let area = geometry.imageArea(slot)
            fill(area, color: Palette.tile, in: ctx)
            if let photo = project[slot], let image = images[slot] {
                ctx.saveGState()
                ctx.clip(to: area)
                image.draw(in: geometry.photo(photo.asset.pixels, pose: photo.pose, slot: slot))
                ctx.restoreGState()
            }
            if project.labels {
                let label = geometry.label(slot)
                fill(label, color: Palette.label(slot), in: ctx)
                drawText(L.t(slot.key), in: label, size: geometry.labelFont, color: Palette.green)
            }
        }
    }

    private static func fill(_ rect: CGRect, color: UIColor, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    private static func drawText(_ value: String, in rect: CGRect, size: CGFloat, color: UIColor,
                                 alignment: NSTextAlignment = .center, lines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSAttributedString(string: value, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: color
        ])
        let height = min(rect.height, font.lineHeight * CGFloat(lines))
        let fit = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        text.draw(with: fit, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
