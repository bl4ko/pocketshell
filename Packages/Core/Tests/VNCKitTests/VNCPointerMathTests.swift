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
