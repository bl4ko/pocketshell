import CoreGraphics

enum BoxDrawing {
    static func handles(_ scalar: UInt32) -> Bool {
        arms(scalar) != nil || rounded(scalar) != nil || (0x2580...0x259f).contains(scalar)
    }

    static func draw(_ scalar: UInt32, in context: CGContext, width: Int, height: Int, thickness: Int) -> Bool {
        let w = CGFloat(width)
        let h = CGFloat(height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        if let arms = arms(scalar) {
            drawArms(arms, context: context, w: w, h: h, light: CGFloat(max(1, thickness)))
            return true
        }
        if let corner = rounded(scalar) {
            drawRounded(corner, context: context, w: w, h: h, light: CGFloat(max(1, thickness)))
            return true
        }
        return drawBlock(scalar, context: context, w: w, h: h)
    }

    private static let table: [UInt32: [UInt8]] = {
        var table: [UInt32: [UInt8]] = [:]
        let entries: [(UInt32, [UInt8])] = [
            (0x2500, [0, 1, 0, 1]), (0x2501, [0, 2, 0, 2]), (0x2502, [1, 0, 1, 0]), (0x2503, [2, 0, 2, 0]),
            (0x2504, [0, 1, 0, 1]), (0x2505, [0, 2, 0, 2]), (0x2506, [1, 0, 1, 0]), (0x2507, [2, 0, 2, 0]),
            (0x2508, [0, 1, 0, 1]), (0x2509, [0, 2, 0, 2]), (0x250A, [1, 0, 1, 0]), (0x250B, [2, 0, 2, 0]),
            (0x250C, [0, 1, 1, 0]), (0x250D, [0, 2, 1, 0]), (0x250E, [0, 1, 2, 0]), (0x250F, [0, 2, 2, 0]),
            (0x2510, [0, 0, 1, 1]), (0x2511, [0, 0, 1, 2]), (0x2512, [0, 0, 2, 1]), (0x2513, [0, 0, 2, 2]),
            (0x2514, [1, 1, 0, 0]), (0x2515, [1, 2, 0, 0]), (0x2516, [2, 1, 0, 0]), (0x2517, [2, 2, 0, 0]),
            (0x2518, [1, 0, 0, 1]), (0x2519, [1, 0, 0, 2]), (0x251A, [2, 0, 0, 1]), (0x251B, [2, 0, 0, 2]),
            (0x251C, [1, 1, 1, 0]), (0x251D, [1, 2, 1, 0]), (0x251E, [2, 1, 1, 0]), (0x251F, [1, 1, 2, 0]),
            (0x2520, [2, 1, 2, 0]), (0x2521, [2, 2, 1, 0]), (0x2522, [1, 2, 2, 0]), (0x2523, [2, 2, 2, 0]),
            (0x2524, [1, 0, 1, 1]), (0x2525, [1, 0, 1, 2]), (0x2526, [2, 0, 1, 1]), (0x2527, [1, 0, 2, 1]),
            (0x2528, [2, 0, 2, 1]), (0x2529, [2, 0, 1, 2]), (0x252A, [1, 0, 2, 2]), (0x252B, [2, 0, 2, 2]),
            (0x252C, [0, 1, 1, 1]), (0x252D, [0, 1, 1, 2]), (0x252E, [0, 2, 1, 1]), (0x252F, [0, 2, 1, 2]),
            (0x2530, [0, 1, 2, 1]), (0x2531, [0, 1, 2, 2]), (0x2532, [0, 2, 2, 1]), (0x2533, [0, 2, 2, 2]),
            (0x2534, [1, 1, 0, 1]), (0x2535, [1, 1, 0, 2]), (0x2536, [1, 2, 0, 1]), (0x2537, [1, 2, 0, 2]),
            (0x2538, [2, 1, 0, 1]), (0x2539, [2, 1, 0, 2]), (0x253A, [2, 2, 0, 1]), (0x253B, [2, 2, 0, 2]),
            (0x253C, [1, 1, 1, 1]), (0x253D, [1, 1, 1, 2]), (0x253E, [1, 2, 1, 1]), (0x253F, [1, 2, 1, 2]),
            (0x2540, [2, 1, 1, 1]), (0x2541, [1, 1, 2, 1]), (0x2542, [2, 1, 2, 1]), (0x2543, [2, 1, 1, 2]),
            (0x2544, [2, 2, 1, 1]), (0x2545, [1, 1, 2, 2]), (0x2546, [1, 2, 2, 1]), (0x2547, [2, 2, 1, 2]),
            (0x2548, [1, 2, 2, 2]), (0x2549, [2, 1, 2, 2]), (0x254A, [2, 2, 2, 1]), (0x254B, [2, 2, 2, 2]),
            (0x254C, [0, 1, 0, 1]), (0x254D, [0, 2, 0, 2]), (0x254E, [1, 0, 1, 0]), (0x254F, [2, 0, 2, 0]),
            (0x2550, [0, 3, 0, 3]), (0x2551, [3, 0, 3, 0]), (0x2552, [0, 3, 1, 0]), (0x2553, [0, 1, 3, 0]),
            (0x2554, [0, 3, 3, 0]), (0x2555, [0, 0, 1, 3]), (0x2556, [0, 0, 3, 1]), (0x2557, [0, 0, 3, 3]),
            (0x2558, [1, 3, 0, 0]), (0x2559, [3, 1, 0, 0]), (0x255A, [3, 3, 0, 0]), (0x255B, [1, 0, 0, 3]),
            (0x255C, [3, 0, 0, 1]), (0x255D, [3, 0, 0, 3]), (0x255E, [1, 3, 1, 0]), (0x255F, [3, 1, 3, 0]),
            (0x2560, [3, 3, 3, 0]), (0x2561, [1, 0, 1, 3]), (0x2562, [3, 0, 3, 1]), (0x2563, [3, 0, 3, 3]),
            (0x2564, [0, 3, 1, 3]), (0x2565, [0, 1, 3, 1]), (0x2566, [0, 3, 3, 3]), (0x2567, [1, 3, 0, 3]),
            (0x2568, [3, 1, 0, 1]), (0x2569, [3, 3, 0, 3]), (0x256A, [1, 3, 1, 3]), (0x256B, [3, 1, 3, 1]),
            (0x256C, [3, 3, 3, 3]), (0x2574, [0, 0, 0, 1]), (0x2575, [1, 0, 0, 0]), (0x2576, [0, 1, 0, 0]),
            (0x2577, [0, 0, 1, 0]), (0x2578, [0, 0, 0, 2]), (0x2579, [2, 0, 0, 0]), (0x257A, [0, 2, 0, 0]),
            (0x257B, [0, 0, 2, 0]), (0x257C, [0, 2, 0, 1]), (0x257D, [1, 0, 2, 0]), (0x257E, [0, 1, 0, 2]),
            (0x257F, [2, 0, 1, 0]),
        ]
        for (scalar, arms) in entries { table[scalar] = arms }
        return table
    }()

    static func arms(_ scalar: UInt32) -> [UInt8]? {
        table[scalar]
    }

    static func rounded(_ scalar: UInt32) -> (right: Bool, down: Bool)? {
        switch scalar {
        case 0x256D: (true, true)
        case 0x256E: (false, true)
        case 0x256F: (false, false)
        case 0x2570: (true, false)
        default: nil
        }
    }

    private static func drawArms(_ arms: [UInt8], context: CGContext, w: CGFloat, h: CGFloat, light: CGFloat) {
        let cx = (w / 2).rounded(.down)
        let cy = (h / 2).rounded(.down)
        func weight(_ value: UInt8) -> CGFloat { value == 2 ? light * 2 : light }
        let gap = light
        for (index, value) in arms.enumerated() where value != 0 {
            let t = weight(value)
            let offsets: [CGFloat] = value == 3 ? [-gap, gap] : [0]
            let horizontalExtent = arms[0] != 0 || arms[2] != 0 ? weight(max(arms[0], arms[2])) / 2 : 0
            let verticalExtent = arms[1] != 0 || arms[3] != 0 ? weight(max(arms[1], arms[3])) / 2 : 0
            for offset in offsets {
                switch index {
                case 0:
                    let x = cx - (t / 2).rounded(.down) + offset
                    context.fill(CGRect(x: x, y: cy - verticalExtent, width: t, height: h - cy + verticalExtent))
                case 2:
                    let x = cx - (t / 2).rounded(.down) + offset
                    context.fill(CGRect(x: x, y: 0, width: t, height: cy + verticalExtent + t / 2))
                case 1:
                    let y = cy - (t / 2).rounded(.down) + offset
                    context.fill(CGRect(x: cx - horizontalExtent, y: y, width: w - cx + horizontalExtent, height: t))
                default:
                    let y = cy - (t / 2).rounded(.down) + offset
                    context.fill(CGRect(x: 0, y: y, width: cx + horizontalExtent + t / 2, height: t))
                }
            }
        }
    }

    private static func drawRounded(
        _ corner: (right: Bool, down: Bool), context: CGContext, w: CGFloat, h: CGFloat, light: CGFloat
    ) {
        let cx = (w / 2).rounded(.down) + light / 2
        let cy = (h / 2).rounded(.down) + light / 2
        let radius = min(w, h) / 2
        let horizontalEnd = CGPoint(x: corner.right ? w : 0, y: cy)
        let verticalEnd = CGPoint(x: cx, y: corner.down ? 0 : h)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(light)
        context.move(to: horizontalEnd)
        context.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: verticalEnd, radius: radius)
        context.addLine(to: verticalEnd)
        context.strokePath()
    }

    private static func drawBlock(_ scalar: UInt32, context: CGContext, w: CGFloat, h: CGFloat) -> Bool {
        func fill(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            context.fill(
                CGRect(
                    x: (x0 * w).rounded(), y: h - (y1 * h).rounded(), width: ((x1 - x0) * w).rounded(),
                    height: ((y1 - y0) * h).rounded()))
        }
        switch scalar {
        case 0x2580: fill(0, 0, 1, 0.5)
        case 0x2581...0x2587: fill(0, 1 - CGFloat(scalar - 0x2580) / 8, 1, 1)
        case 0x2588: fill(0, 0, 1, 1)
        case 0x2589...0x258F: fill(0, 0, CGFloat(0x2590 - scalar) / 8, 1)
        case 0x2590: fill(0.5, 0, 1, 1)
        case 0x2591, 0x2592, 0x2593:
            context.setFillColor(CGColor(gray: 1, alpha: [0.25, 0.5, 0.75][Int(scalar - 0x2591)]))
            fill(0, 0, 1, 1)
        case 0x2594: fill(0, 0, 1, 0.125)
        case 0x2595: fill(0.875, 0, 1, 1)
        case 0x2596...0x259F:
            let quadrants: [[Int]] = [
                [2], [3], [0], [0, 2, 3], [0, 3], [0, 1, 2], [0, 1, 3], [1], [1, 2], [1, 2, 3],
            ]
            for quadrant in quadrants[Int(scalar - 0x2596)] {
                let x0: CGFloat = quadrant % 2 == 0 ? 0 : 0.5
                let y0: CGFloat = quadrant < 2 ? 0 : 0.5
                fill(x0, y0, x0 + 0.5, y0 + 0.5)
            }
        default:
            return false
        }
        return true
    }
}
