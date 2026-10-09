import CoreGraphics
import Testing

@testable import VNCKit

private let view = CGSize(width: 400, height: 300)
private let image = CGSize(width: 1600, height: 900)

@Test func centerTouchMapsToImageCenter() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image, zoom: 1, offset: .zero
    )
    #expect(point == CGPoint(x: 800, y: 450))
}

@Test func leftEdgeTouchMapsToImageLeftEdge() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 0, y: 150), viewSize: view, imageSize: image, zoom: 1, offset: .zero
    )
    #expect(point == CGPoint(x: 0, y: 450))
}

@Test func touchInLetterboxReturnsNil() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 200, y: 30), viewSize: view, imageSize: image, zoom: 1, offset: .zero
    )
    #expect(point == nil)
}

@Test func zoomedTouchScalesAroundCenter() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 300, y: 150), viewSize: view, imageSize: image, zoom: 2, offset: .zero
    )
    #expect(point == CGPoint(x: 1000, y: 450))
}

@Test func offsetShiftsImage() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 250, y: 150), viewSize: view, imageSize: image, zoom: 1,
        offset: CGSize(width: 50, height: 0)
    )
    #expect(point == CGPoint(x: 800, y: 450))
}

private func near(_ point: CGPoint?, _ expected: CGPoint) -> Bool {
    guard let point else { return false }
    return abs(point.x - expected.x) < 0.001 && abs(point.y - expected.y) < 0.001
}

@Test func fillModeCenterTouchMapsToImageCenter() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 200, y: 150), viewSize: view, imageSize: image, zoom: 1, offset: .zero, fill: true
    )
    #expect(near(point, CGPoint(x: 800, y: 450)))
}

@Test func fillModeTopEdgeTouchMapsToImageTopEdge() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 200, y: 0), viewSize: view, imageSize: image, zoom: 1, offset: .zero, fill: true
    )
    #expect(near(point, CGPoint(x: 800, y: 0)))
}

@Test func fillModeLeftEdgeTouchMapsInsideCroppedImage() {
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 0, y: 150), viewSize: view, imageSize: image, zoom: 1, offset: .zero, fill: true
    )
    #expect(near(point, CGPoint(x: 200, y: 450)))
}

@Test func clampedPixelStaysInsideFramebuffer() {
    let pixel = VNCPointerMath.clampedPixel(CGPoint(x: 1600, y: -3), imageSize: image)
    #expect(pixel.x == 1599)
    #expect(pixel.y == 0)
}

@Test func clampedOffsetIsZeroAtUnitZoom() {
    let offset = VNCPointerMath.clampedOffset(CGSize(width: 90, height: -40), viewSize: view, zoom: 1)
    #expect(offset == .zero)
}

@Test func clampedOffsetBoundsBothAxesAtFourTimesZoom() {
    let high = VNCPointerMath.clampedOffset(CGSize(width: 9999, height: 9999), viewSize: view, zoom: 4)
    #expect(high == CGSize(width: 600, height: 450))
    let low = VNCPointerMath.clampedOffset(CGSize(width: -9999, height: -9999), viewSize: view, zoom: 4)
    #expect(low == CGSize(width: -600, height: -450))
    let inside = VNCPointerMath.clampedOffset(CGSize(width: 10, height: -20), viewSize: view, zoom: 4)
    #expect(inside == CGSize(width: 10, height: -20))
}

@Test func clampedOffsetShrinksWhenZoomDecreases() {
    let offset = VNCPointerMath.clampedOffset(CGSize(width: 600, height: -450), viewSize: view, zoom: 2)
    #expect(offset == CGSize(width: 200, height: -150))
}

@Test func clampedOffsetKeepsViewEdgeInsideFramebuffer() {
    let offset = VNCPointerMath.clampedOffset(CGSize(width: 9999, height: 9999), viewSize: view, zoom: 4)
    let point = VNCPointerMath.framebufferPoint(
        touch: CGPoint(x: 0, y: 0), viewSize: view, imageSize: CGSize(width: 400, height: 300), zoom: 4,
        offset: offset)
    #expect(near(point, CGPoint(x: 0, y: 0)))
}
