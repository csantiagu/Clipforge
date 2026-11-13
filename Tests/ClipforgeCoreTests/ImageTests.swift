#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipforgeCore

/// Builds real images with ImageIO and checks what the processor writes.
/// The test photo is 400×300, stored sideways (EXIF orientation 6, as phones do), with a
/// red block in its stored top-left corner, GPS, camera, date, owner and serial number.
final class ImageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipforge-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Reading

    func testReadsSensitiveMetadata() throws {
        let info = try ImageProcessor.readInfo(try makePhoto())
        XCTAssertEqual(info.pixelWidth, 400)
        XCTAssertEqual(info.pixelHeight, 300)
        XCTAssertEqual(info.orientation, 6)
        XCTAssertEqual(info.displayWidth, 300, "orientation 6 displays rotated")
        XCTAssertEqual(info.displayHeight, 400)
        XCTAssertTrue(info.hasLocation)
        let labels = Set(info.metadata.map(\.label))
        XCTAssertTrue(labels.isSuperset(of: ["Location", "Camera", "Taken", "Owner", "Serial number"]), "\(labels)")
        XCTAssertEqual(info.metadata.first { $0.label == "Camera" }?.value, "Testmaker X100")
        XCTAssertTrue(info.metadata.first { $0.label == "Location" }?.value.contains("51.5") ?? false)
    }

    func testRejectsNonImages() throws {
        let text = directory.appendingPathComponent("notes.jpg")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ImageProcessor.readInfo(text))
    }

    // MARK: Metadata

    func testRemoveAllWhenRecompressing() throws {
        let photo = try makePhoto()
        var settings = ImageSettings()
        settings.metadata = .removeAll
        let (result, out) = try process(photo, settings)
        XCTAssertFalse(result.lossless)
        XCTAssertTrue(out.metadata.isEmpty, "left behind: \(out.metadata)")
        // Pixels were turned upright, so no rotation flag is needed any more.
        XCTAssertEqual(out.orientation, 1)
        XCTAssertEqual(out.pixelWidth, 300)
        XCTAssertEqual(out.pixelHeight, 400)
        XCTAssertTrue(isRed(try pixel(result.data, x: 300 - 10, y: 10)),
                      "stored top-left must end up top-right after rotating 90° clockwise")
    }

    func testStripMetadataWithoutRecompressing() throws {
        let photo = try makePhoto()
        let preset = try XCTUnwrap(ImagePreset.builtIn.first { $0.name == "Strip metadata" })
        let (result, out) = try process(photo, preset.settings)
        XCTAssertTrue(result.lossless, "JPEG metadata should be removed without re-encoding")
        XCTAssertFalse(out.hasLocation)
        XCTAssertTrue(out.metadata.isEmpty, "left behind: \(out.metadata)")
        XCTAssertEqual(out.orientation, 6, "keeps the rotation flag so the photo still shows upright")
        XCTAssertEqual(try decodedBytes(Data(contentsOf: photo)), try decodedBytes(result.data),
                       "image data must be identical")
    }

    func testRemoveLocationOnly() throws {
        var settings = ImageSettings()
        settings.metadata = .removeLocation
        let (_, out) = try process(try makePhoto(), settings)
        XCTAssertFalse(out.hasLocation)
        XCTAssertTrue(out.metadata.contains { $0.label == "Camera" }, "camera details are kept")
    }

    func testRemoveLocationOnlyLossless() throws {
        var settings = ImageSettings()
        settings.compress = false
        settings.metadata = .removeLocation
        let (result, out) = try process(try makePhoto(), settings)
        XCTAssertTrue(result.lossless)
        XCTAssertFalse(out.hasLocation)
        XCTAssertTrue(out.metadata.contains { $0.label == "Camera" })
    }

    func testKeepAll() throws {
        var settings = ImageSettings()
        settings.metadata = .keepAll
        let (_, out) = try process(try makePhoto(), settings)
        XCTAssertTrue(out.hasLocation)
        XCTAssertEqual(out.orientation, 1)
    }

    // MARK: Size

    func testResizeKeepsAspectAndNeverEnlarges() throws {
        var settings = ImageSettings()
        settings.maxDimension = 200
        let (_, small) = try process(try makePhoto(), settings)
        XCTAssertEqual(max(small.pixelWidth, small.pixelHeight), 200)
        XCTAssertEqual(min(small.pixelWidth, small.pixelHeight), 150)

        settings.maxDimension = 4000
        let (_, same) = try process(try makePhoto(), settings)
        XCTAssertEqual(max(same.pixelWidth, same.pixelHeight), 400)
    }

    func testLowerQualityIsSmaller() throws {
        let photo = try makePhoto(noise: true)
        var settings = ImageSettings()
        settings.quality = 90
        let high = try process(photo, settings).0.data.count
        settings.quality = 30
        let low = try process(photo, settings).0.data.count
        XCTAssertLessThan(low, high)
    }

    // MARK: Formats

    func testTransparentPNGToJPEGBecomesWhite() throws {
        let png = try makeTransparentPNG()
        var settings = ImageSettings()
        settings.format = .jpeg
        let (result, out) = try process(png, settings)
        XCTAssertTrue(out.type.conforms(to: .jpeg))
        let corner = try pixel(result.data, x: 2, y: 2)
        XCTAssertGreaterThan(corner.r, 240, "transparent areas must not turn black")
        XCTAssertGreaterThan(corner.g, 240)
    }

    func testHEICOutputWhenSupported() throws {
        guard ImageProcessor.writableFormats().contains(.heic) else { throw XCTSkip("HEIC writing not available on this Mac") }
        var settings = ImageSettings()
        settings.format = .heic
        let (result, out) = try process(try makePhoto(), settings)
        XCTAssertTrue(out.type.conforms(to: .heic) || out.type.conforms(to: .heif), "\(out.type)")
        XCTAssertFalse(out.hasLocation)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    func testWritableFormatsIncludeTheBasics() {
        XCTAssertTrue(ImageProcessor.writableFormats().isSuperset(of: [.original, .jpeg, .png, .tiff]))
    }

    // MARK: Naming

    func testOutputNames() throws {
        let photo = try makePhoto()
        let info = try ImageProcessor.readInfo(photo)
        var settings = ImageSettings()
        XCTAssertEqual(ImageProcessor.fileExtension(for: photo, info: info, settings: settings), "jpg")
        XCTAssertEqual(OutputNamer.outputURL(for: photo, fileExtension: "jpg", exists: { _ in false }).lastPathComponent,
                       "photo_new.jpg", "same format next to the original gets _new")
        settings.format = .png
        XCTAssertEqual(ImageProcessor.fileExtension(for: photo, info: info, settings: settings), "png")
        let heic = URL(fileURLWithPath: "/p/IMG_0001.HEIC")
        XCTAssertEqual(OutputNamer.outputURL(for: heic, fileExtension: "jpg", exists: { _ in false }).lastPathComponent,
                       "IMG_0001.jpg")
    }

    func testLosslessOnlyWhenNothingElseChanges() throws {
        let info = try ImageProcessor.readInfo(try makePhoto())
        var settings = ImageSettings()
        settings.compress = false
        XCTAssertTrue(ImageProcessor.canCopyLosslessly(info, settings: settings))
        settings.maxDimension = 100
        XCTAssertFalse(ImageProcessor.canCopyLosslessly(info, settings: settings), "resizing needs re-encoding")
        settings.maxDimension = 0
        settings.format = .png
        XCTAssertFalse(ImageProcessor.canCopyLosslessly(info, settings: settings), "format change needs re-encoding")
    }

    // MARK: Helpers

    private func process(_ url: URL, _ settings: ImageSettings) throws -> (ImageResult, ImageInfo) {
        let info = try ImageProcessor.readInfo(url)
        let result = try ImageProcessor.process(url, info: info, settings: settings)
        return (result, try ImageProcessor.readInfo(data: result.data))
    }

    /// 400×300 JPEG, orientation 6, red block in the stored top-left corner.
    private func makePhoto(noise: Bool = false) throws -> URL {
        let width = 400, height = 300
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise {
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<4000 {
                context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                             blue: .random(in: 0...1, using: &generator), alpha: 1))
                context.fill(CGRect(x: Int.random(in: 0..<width), y: Int.random(in: 0..<height), width: 3, height: 3))
            }
        }
        // CoreGraphics' origin is bottom-left, so the stored top-left is at high y.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 60, width: 80, height: 60))
        let image = try XCTUnwrap(context.makeImage())

        let url = directory.appendingPathComponent("photo.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Testmaker",
                kCGImagePropertyTIFFModel: "Testmaker X100",
                kCGImagePropertyTIFFOrientation: 6,
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:19 12:00:00",
                kCGImagePropertyExifCameraOwnerName: "Jane Example",
                kCGImagePropertyExifBodySerialNumber: "SN-123456",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5007,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1246,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// 64×64 PNG, transparent except a red square in the middle.
    private func makeTransparentPNG() throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        let url = directory.appendingPathComponent("logo.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private struct RGB { let r: Int, g: Int, b: Int }

    /// Pixel at (x, y) measured from the top-left of the stored image.
    private func pixel(_ data: Data, x: Int, y: Int) throws -> RGB {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Draw so that the wanted pixel lands on the 1×1 canvas.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return RGB(r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2]))
    }

    private func isRed(_ p: RGB) -> Bool { p.r > 180 && p.g < 90 && p.b < 90 }

    /// Decoded pixels, to prove a copy didn't re-encode.
    private func decodedBytes(_ data: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }
}
#endif
