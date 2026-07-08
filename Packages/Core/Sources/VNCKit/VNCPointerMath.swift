import CoreGraphics

public enum VNCPointerMath {
    public static func framebufferPoint(
        touch: CGPoint,
        viewSize: CGSize,
        imageSize: CGSize,
        zoom: CGFloat,
        offset: CGSize,
        fill: Bool = false
    ) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return nil
        }
        let widthScale = viewSize.width / imageSize.width
        let heightScale = viewSize.height / imageSize.height
        let fitScale = fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let scale = fitScale * zoom
        guard scale > 0 else { return nil }
        let displayed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = viewSize.width / 2 + offset.width - displayed.width / 2
        let originY = viewSize.height / 2 + offset.height - displayed.height / 2
        let x = (touch.x - originX) / scale
        let y = (touch.y - originY) / scale
        guard x >= 0, x <= imageSize.width, y >= 0, y <= imageSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    public static func clampedPixel(_ point: CGPoint, imageSize: CGSize) -> (x: UInt16, y: UInt16) {
        let x = min(max(point.x, 0), imageSize.width - 1)
        let y = min(max(point.y, 0), imageSize.height - 1)
        return (UInt16(x), UInt16(y))
    }
}
