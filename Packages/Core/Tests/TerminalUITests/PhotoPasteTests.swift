#if os(iOS)
    import Testing
    import UIKit

    @testable import TerminalUI

    @MainActor
    private func photo(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor
    @Test func pastedPhotoUploadsAsJPEG() throws {
        let bridge = TerminalBridge()
        var uploads: [Data] = []
        bridge.imagePaste = { uploads.append($0) }
        bridge.pastePhoto(photo(CGSize(width: 64, height: 48)))
        let data = try #require(uploads.first)
        #expect(uploads.count == 1)
        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(UIImage(data: data)?.size == CGSize(width: 64, height: 48))
    }

    @MainActor
    @Test func pastedCameraPhotoIsDownscaled() throws {
        let bridge = TerminalBridge()
        var uploads: [Data] = []
        bridge.imagePaste = { uploads.append($0) }
        bridge.pastePhoto(photo(CGSize(width: 4032, height: 3024)))
        let image = try #require(uploads.first.flatMap { UIImage(data: $0) })
        #expect(max(image.size.width, image.size.height) * image.scale <= 1568)
    }

    @MainActor
    @Test func photoWithoutSessionIsDropped() {
        TerminalBridge().pastePhoto(photo(CGSize(width: 8, height: 8)))
    }
#endif
