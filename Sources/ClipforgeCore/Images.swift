#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Image conversion uses Apple's ImageIO rather than ffmpeg: it reads HEIC, RAW, WebP and AVIF,
// writes HEIC, and understands photo metadata (EXIF, GPS, IPTC, XMP).

public enum ImageFormat: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case original, jpeg, heic, png, tiff

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "Same"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }

    public var utType: UTType? {
        switch self {
        case .original: return nil
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        case .tiff: return .tiff
        }
    }
}

public enum MetadataMode: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case removeAll, removeLocation, keepAll

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .removeAll: return "Remove all"
        case .removeLocation: return "Location only"
        case .keepAll: return "Keep"
        }
    }
}

public struct ImageSettings: Equatable, Hashable, Codable, Sendable {
    public var format: ImageFormat = .original
    /// Off: keep the original compression where possible (no quality loss).
    public var compress: Bool = true
    /// 10–100, used by JPEG and HEIC.
    public var quality: Int = 80
    /// Longest side in pixels; 0 keeps the original size. Images are never enlarged.
    public var maxDimension: Int = 0
    public var metadata: MetadataMode = .removeAll

    public init() {}
}

public struct ImagePreset: Identifiable, Sendable {
    public let name: String
    public let summary: String
    public let systemImage: String
    public let settings: ImageSettings
    public var id: String { name }

    public static let builtIn: [ImagePreset] = {
        var share = ImageSettings()
        share.maxDimension = 2048
        share.quality = 80

        var smallest = ImageSettings()
        smallest.format = .heic
        smallest.quality = 60
        smallest.maxDimension = 1600

        var strip = ImageSettings()
        strip.compress = false

        var jpeg = ImageSettings()
        jpeg.format = .jpeg
        jpeg.quality = 85
        jpeg.metadata = .removeLocation

        return [
            ImagePreset(name: "Share safely", summary: "Same format, longest side 2048 px, all metadata removed. Good for messages and the web.",
                        systemImage: "paperplane.fill", settings: share),
            ImagePreset(name: "Smallest", summary: "HEIC at 1600 px. About a tenth of a typical phone photo. HEIC opens on Apple devices and modern Windows.",
                        systemImage: "arrow.down.right.and.arrow.up.left", settings: smallest),
            ImagePreset(name: "Strip metadata", summary: "Removes location, camera and dates without re-compressing JPEG, PNG or TIFF, so quality is untouched.",
                        systemImage: "eye.slash.fill", settings: strip),
            ImagePreset(name: "To JPEG", summary: "Turns HEIC or PNG into JPEG, which opens everywhere. Removes location, keeps camera details.",
                        systemImage: "photo.fill", settings: jpeg),
        ]
    }()
}

/// One piece of metadata found in a file, shown so people can see what will be removed.
public struct MetadataItem: Hashable, Sendable {
    public let label: String
    public let value: String
    /// Location, serial numbers and owner names: things people usually don't mean to share.
    public let isSensitive: Bool
}

public struct ImageInfo: Sendable {
    public let type: UTType
    /// Pixel size as stored, before applying the orientation.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// EXIF orientation, 1–8.
    public let orientation: Int
    public let fileSize: Int64
    public let frameCount: Int
    public let hasAlpha: Bool
    public let metadata: [MetadataItem]

    public var hasLocation: Bool { metadata.contains { $0.label == "Location" } }

    /// Size as the image is displayed (orientations 5–8 swap width and height).
    public var displayWidth: Int { orientation >= 5 ? pixelHeight : pixelWidth }
    public var displayHeight: Int { orientation >= 5 ? pixelWidth : pixelHeight }

    public var formatName: String {
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        return (type.preferredFilenameExtension ?? type.identifier).uppercased()
    }
}

public struct ImageResult {
    public let data: Data
    public let type: UTType
    /// True when the original image data was copied and only the metadata changed.
    public let lossless: Bool
}

public enum ImageError: LocalizedError {
    case unreadable
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This file isn't an image macOS can read."
        case .cannotWrite(let format): return "Couldn't save as \(format)."
        }
    }
}

public enum ImageProcessor {
    /// Formats this Mac can write.
    public static func writableFormats() -> Set<ImageFormat> {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        var formats: Set<ImageFormat> = [.original]
        for format in ImageFormat.allCases {
            if let type = format.utType, identifiers.contains(type.identifier) { formats.insert(format) }
        }
        return formats
    }

    // MARK: Reading

    public static func readInfo(_ url: URL) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ImageError.unreadable
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return ImageInfo(
            type: type,
            pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1,
            fileSize: size,
            frameCount: CGImageSourceGetCount(source),
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            metadata: metadataItems(properties)
        )
    }

    static func metadataItems(_ properties: [CFString: Any]) -> [MetadataItem] {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var items: [MetadataItem] = []

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let ew = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            items.append(MetadataItem(label: "Location", value: String(format: "%.4f° ", lat) + ns + String(format: ", %.4f° ", lon) + ew,
                                      isSensitive: true))
        } else if !gps.isEmpty {
            items.append(MetadataItem(label: "Location", value: "GPS data", isSensitive: true))
        }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !camera.isEmpty {
            // "Apple iPhone 15 Pro" rather than "Apple Apple iPhone…" when the model repeats the make.
            let text = camera.count == 2 && camera[1].hasPrefix(camera[0]) ? camera[1] : camera.joined(separator: " ")
            items.append(MetadataItem(label: "Camera", value: text, isSensitive: false))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String {
            items.append(MetadataItem(label: "Lens", value: lens, isSensitive: false))
        }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            items.append(MetadataItem(label: "Taken", value: taken, isSensitive: false))
        }
        if let owner = exif[kCGImagePropertyExifCameraOwnerName] as? String ?? tiff[kCGImagePropertyTIFFArtist] as? String {
            items.append(MetadataItem(label: "Owner", value: owner, isSensitive: true))
        }
        if let serial = exif[kCGImagePropertyExifBodySerialNumber] as? String {
            items.append(MetadataItem(label: "Serial number", value: serial, isSensitive: true))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            items.append(MetadataItem(label: "Software", value: software, isSensitive: false))
        }
        if properties[kCGImagePropertyIPTCDictionary] != nil {
            items.append(MetadataItem(label: "IPTC", value: "Captions, keywords or credits", isSensitive: false))
        }
        return items
    }

    /// A small upright preview for the queue.
    public static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Output naming

    public static func outputType(for info: ImageInfo, settings: ImageSettings) -> UTType {
        settings.format.utType ?? info.type
    }

    /// The source's own extension when the format stays the same (so IMG.JPEG stays .JPEG-style),
    /// otherwise the standard one for the new format.
    public static func fileExtension(for input: URL, info: ImageInfo, settings: ImageSettings) -> String {
        let type = outputType(for: info, settings: settings)
        if type == info.type, !input.pathExtension.isEmpty { return input.pathExtension.lowercased() }
        if type.conforms(to: .heic) { return "heic" }
        if type.conforms(to: .jpeg) { return "jpg" }
        return type.preferredFilenameExtension ?? "img"
    }

    // MARK: Processing

    /// Whether the image data can be copied as-is with only the metadata changed.
    public static func canCopyLosslessly(_ info: ImageInfo, settings: ImageSettings) -> Bool {
        let losslessTypes: [UTType] = [.jpeg, .png, .tiff]
        let fits = settings.maxDimension == 0 || max(info.pixelWidth, info.pixelHeight) <= settings.maxDimension
        return !settings.compress
            && outputType(for: info, settings: settings) == info.type
            && fits
            && info.frameCount == 1
            && losslessTypes.contains { info.type.conforms(to: $0) }
    }

    /// Converts one image in memory. Nothing is written to disk.
    public static func process(_ url: URL, info: ImageInfo, settings: ImageSettings) throws -> ImageResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageError.unreadable }
        let type = outputType(for: info, settings: settings)
        if canCopyLosslessly(info, settings: settings), let data = copyLosslessly(source, type: type, info: info, settings: settings) {
            return ImageResult(data: data, type: type, lossless: true)
        }
        return ImageResult(data: try reencode(source, type: type, info: info, settings: settings), type: type, lossless: false)
    }

    /// Copies the compressed image data and rewrites only the metadata.
    static func copyLosslessly(_ source: CGImageSource, type: UTType, info: ImageInfo, settings: ImageSettings) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        switch settings.metadata {
        case .keepAll:
            break
        case .removeLocation:
            // Copy all metadata and delete just the GPS tags, wherever they are stored (EXIF or XMP).
            // (kCGImageMetadataShouldExcludeXMP looked tempting but also drops camera and date.)
            guard let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
                  let metadata = CGImageMetadataCreateMutableCopy(original) else { return nil }
            var gpsPaths: [CFString] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                if let name = CGImageMetadataTagCopyName(tag) as String?, name.hasPrefix("GPS") { gpsPaths.append(path) }
                return true
            }
            for path in gpsPaths { _ = CGImageMetadataRemoveTagWithPath(metadata, nil, path) }
            options[kCGImageDestinationMetadata] = metadata
            options[kCGImageDestinationMergeMetadata] = false
            options[kCGImageMetadataShouldExcludeGPS] = true
        case .removeAll:
            // Replace everything with metadata that holds only the orientation, so the
            // picture still displays the right way up.
            let metadata = CGImageMetadataCreateMutable()
            if info.orientation != 1 {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                                 kCGImagePropertyTIFFOrientation, NSNumber(value: info.orientation))
            }
            options[kCGImageDestinationMetadata] = metadata
            options[kCGImageDestinationMergeMetadata] = false
            options[kCGImageMetadataShouldExcludeGPS] = true
            options[kCGImageMetadataShouldExcludeXMP] = true
        }
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return nil }
        let result = data as Data
        // Only trust the copy if what was asked to go is really gone.
        if settings.metadata != .keepAll, let check = try? readInfo(data: result), check.hasLocation { return nil }
        if settings.metadata == .removeAll, let check = try? readInfo(data: result),
           check.metadata.contains(where: { $0.label != "Software" }) {
            return nil
        }
        return result
    }

    static func reencode(_ source: CGImageSource, type: UTType, info: ImageInfo, settings: ImageSettings) throws -> Data {
        let longest = max(info.pixelWidth, info.pixelHeight)
        let target = settings.maxDimension > 0 ? min(settings.maxDimension, longest) : longest
        // Decoding through the thumbnail API applies the orientation to the pixels and resizes in one go.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw ImageError.unreadable
        }
        if type.conforms(to: .jpeg) && hasAlpha(image) { image = flattenedOnWhite(image) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageError.cannotWrite(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
        }
        var properties: [CFString: Any] = [:]
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
            let quality = settings.compress ? Double(min(max(settings.quality, 10), 100)) / 100 : 0.92
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if settings.metadata != .removeAll,
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            var keys = [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
            if settings.metadata == .keepAll { keys.append(kCGImagePropertyGPSDictionary) }
            for key in keys { if let value = original[key] { properties[key] = value } }
            // The pixels are upright now, and the size may have changed.
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.cannotWrite(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
        }
        return data as Data
    }

    public static func readInfo(data: Data) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ImageError.unreadable
        }
        return ImageInfo(
            type: type,
            pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1,
            fileSize: Int64(data.count),
            frameCount: CGImageSourceGetCount(source),
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            metadata: metadataItems(properties)
        )
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// JPEG has no transparency; without this, transparent areas turn black.
    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }
}
#endif
