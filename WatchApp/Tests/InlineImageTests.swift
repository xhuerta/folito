import XCTest
import ReaderCore
@testable import FolitoWatch

/// Pictures in the text (#71): their files, their size in the text, which ones stay decoded, the viewer's zoom,
/// and the reader's handling of image blocks.
final class InlineImageTests: XCTestCase {
    // MARK: Files

    func testImageFilesOnlyForPlainIDs() {
        let files = BookImageFiles(directory: URL(fileURLWithPath: "/tmp/b.images"))
        XCTAssertEqual(files.url(for: "i12")?.lastPathComponent, "i12.img")
        XCTAssertNil(files.url(for: "../x"))
        XCTAssertNil(files.url(for: ""))
        XCTAssertNil(files.url(for: "a/b"))
        XCTAssertNil(files.url(for: "é"))
    }

    private func book(images: [BookImage]?) -> ProcessedBook {
        let blocks = [Block(text: "Text", xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0),
                      Block(text: "", xpointer: "/body/DocFragment[1]/body/img", globalOffset: 4,
                            image: BlockImage(id: "i1", width: 4, height: 3, alt: "A")),
                      Block(text: "More", xpointer: "/body/DocFragment[1]/body/p[2]", globalOffset: 4)]
        return ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h/1", metaHash: "",
                             chapters: [Chapter(spineIndex: 1, title: nil, blocks: blocks)], totalCharacters: 8,
                             images: images)
    }

    private let picture = BookImage(id: "i1", mediaType: "image/jpeg", width: 4, height: 3, data: Data([1, 2, 3, 4]))

    func testImportMovesPicturesIntoFilesAndStoresTheBookWithoutThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookStorage(root: root)
        let file = root.appendingPathComponent("in.book")
        try (JSONEncoder().encode(book(images: [picture])) as NSData).compressed(using: .lzfse).write(to: file)
        let entry = try storage.importBook(from: file)
        let url = try XCTUnwrap(storage.imageFiles(entry.documentHash).url(for: "i1"))
        XCTAssertEqual(try Data(contentsOf: url), picture.data)
        let loaded = try storage.load(documentHash: entry.documentHash)
        XCTAssertNil(loaded.images, "the stored book no longer carries its pictures")
        XCTAssertEqual(loaded.chapters[0].blocks[1].image?.id, "i1")
        storage.delete(documentHash: entry.documentHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.imageDirectory(entry.documentHash).path))
    }

    func testBookStoredWithItsPicturesIsSplitWhenLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookStorage(root: root)
        // As an older watch build stored it: the received file as it was.
        let dest = root.appendingPathComponent("Books").appendingPathComponent(BookStorage.safeName("h/1"))
            .appendingPathExtension("book")
        try (JSONEncoder().encode(book(images: [picture])) as NSData).compressed(using: .lzfse).write(to: dest)
        XCTAssertNil(try storage.load(documentHash: "h/1").images)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(storage.imageFiles("h/1").url(for: "i1"))), picture.data)
        XCTAssertNil(try BookStorage.decode(compressed: Data(contentsOf: dest)).images, "rewritten without them")
    }

    // MARK: Layout

    func testFittedToTheColumnNeverEnlargedNorTooTall() {
        XCTAssertEqual(InlineImageLayout.fittedSize(pixelWidth: 1200, pixelHeight: 900, columnWidth: 180, maxHeight: 200),
                       CGSize(width: 180, height: 135))
        XCTAssertEqual(InlineImageLayout.fittedSize(pixelWidth: 100, pixelHeight: 50, columnWidth: 180, maxHeight: 200),
                       CGSize(width: 100, height: 50), "a small picture stays at one point per pixel")
        XCTAssertEqual(InlineImageLayout.fittedSize(pixelWidth: 400, pixelHeight: 1200, columnWidth: 180, maxHeight: 150),
                       CGSize(width: 50, height: 150), "a tall picture is fitted to the height limit")
        XCTAssertEqual(InlineImageLayout.fittedSize(pixelWidth: 0, pixelHeight: 10, columnWidth: 180, maxHeight: 150), .zero)
        XCTAssertEqual(InlineImageLayout.decodePixels(for: CGSize(width: 180, height: 135), scale: 2), 360)
    }

    func testOnlyNearbyPicturesStayDecoded() {
        XCTAssertTrue(ImageResidency.isNear(10, current: 10))
        XCTAssertTrue(ImageResidency.isNear(10 + ImageResidency.radius, current: 10))
        XCTAssertTrue(ImageResidency.isNear(10 - ImageResidency.radius, current: 10))
        XCTAssertFalse(ImageResidency.isNear(11 + ImageResidency.radius, current: 10))
    }

    func testLRUCacheEvictsTheLeastRecentlyUsed() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.set(3, for: "c")
        XCTAssertNil(cache.value(for: "b"), "b was the least recently used")
        XCTAssertEqual(cache.keys, ["a", "c"])
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: Viewer

    func testZoomClampsAndPansWithinTheEdges() {
        let viewport = CGSize(width: 200, height: 240)
        let fitted = ImageZoom.fitted(aspectRatio: 2, in: viewport)
        XCTAssertEqual(fitted, CGSize(width: 200, height: 100))
        XCTAssertEqual(ImageZoom.fitted(aspectRatio: 0.5, in: viewport), CGSize(width: 120, height: 240))
        var zoom = ImageZoom()
        zoom.pan(from: .zero, by: CGSize(width: 50, height: 50), fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom.offset, .zero, "no panning at fit")
        zoom.setScale(9, fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom.scale, ImageZoom.maxScale)
        zoom.pan(from: .zero, by: CGSize(width: 1000, height: 1000), fitted: fitted, viewport: viewport)
        // 600 x 300 on 200 x 240: 200 to each side, 30 up and down.
        XCTAssertEqual(zoom.offset, CGSize(width: 200, height: 30))
        zoom.setScale(1.5, fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom.offset, CGSize(width: 50, height: 0), "zooming out keeps the picture over the screen")
        zoom.setScale(0.2, fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom.scale, ImageZoom.minScale)
        XCTAssertEqual(zoom.offset, .zero)
    }

    func testDoubleTapSwitchesBetweenFitAndZoomed() {
        let viewport = CGSize(width: 200, height: 240)
        let fitted = ImageZoom.fitted(aspectRatio: 1, in: viewport)
        var zoom = ImageZoom()
        zoom.toggle(fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom.scale, ImageZoom.doubleTapScale)
        zoom.pan(from: .zero, by: CGSize(width: 40, height: 0), fitted: fitted, viewport: viewport)
        zoom.toggle(fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom, ImageZoom(), "back to fit, centred")
        zoom.step(up: true, fitted: fitted, viewport: viewport)
        XCTAssertEqual(zoom.scale, 1.5)
    }

    func testViewerDecodesEnoughForTheZoomButNoMoreThanThePicture() {
        let screen = CGSize(width: 208, height: 248)
        XCTAssertEqual(ImageZoom.decodePixels(screen: screen, scale: 2, pixelWidth: 4000, pixelHeight: 3000), 1488)
        XCTAssertEqual(ImageZoom.decodePixels(screen: screen, scale: 2, pixelWidth: 600, pixelHeight: 400), 600)
    }

    // MARK: Reader

    @MainActor
    func testReaderOpensPicturesAndLooksUpWordsInText() {
        let defaults = UserDefaults(suiteName: "InlineImageTests.\(UUID().uuidString)")!
        let model = ReaderViewModel(book: book(images: nil), positions: PositionStore(defaults: defaults),
                                    sync: SyncCoordinator(defaults: defaults, credentials: { nil }), settings: defaults,
                                    imageFiles: BookImageFiles(directory: URL(fileURLWithPath: "/tmp/x.images")))
        XCTAssertFalse(model.showImage(at: 0), "a text block is not a picture")
        XCTAssertNil(model.openImage)
        XCTAssertTrue(model.showImage(at: 1))
        XCTAssertEqual(model.openImage?.image.alt, "A")
        XCTAssertEqual(model.imageURL(model.openImage!.image)?.lastPathComponent, "i1.img")
        XCTAssertNil(model.imageURL(BlockImage(id: nil, alt: "x")))
        model.beginLookup(at: 1)
        XCTAssertEqual(model.lookupBlockIndex?.index, 2, "the word lookup skips the picture")
        XCTAssertTrue(model.loadsImage(at: 1))
    }
}
