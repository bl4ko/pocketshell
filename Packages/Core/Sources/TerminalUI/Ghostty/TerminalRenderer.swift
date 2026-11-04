import CoreGraphics
import Foundation
import Metal
import VTKit

struct RenderInstance: Equatable {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float> = .zero
    var color: SIMD4<Float>
    var mode: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

struct RenderPalette: Equatable {
    var background: VTColor
    var foreground: VTColor
    var cursor: VTColor
    var selectionBackground = VTColor(r: 0, g: 166, b: 178)
    var selectionForeground = VTColor(r: 0, g: 0, b: 0)
    var handle = VTColor(r: 10, g: 132, b: 255)
}

struct CaretPaint: Equatable {
    enum Style: Equatable {
        case block
        case hollow
    }

    var col: Int
    var row: Int
    var style: Style
}

struct HandlePaint: Equatable {
    var start: (col: Int, row: Int)
    var end: (col: Int, row: Int)

    static func == (lhs: HandlePaint, rhs: HandlePaint) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
    }
}

enum RenderMode {
    static let solid: UInt32 = 0
    static let mask: UInt32 = 1
    static let color: UInt32 = 2
    static let circle: UInt32 = 3
}

final class TerminalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var atlas: GlyphAtlas
    private var backgrounds: [[RenderInstance]] = []
    private var glyphs: [[RenderInstance]] = []
    private var atlasGeneration = 0
    private var palette: RenderPalette
    private var instanceBuffers: [MTLBuffer] = []
    private let busyBuffers = BusyBuffers()
    private(set) var lastInstanceCount = 0

    init?(device: MTLDevice, atlas: GlyphAtlas, palette: RenderPalette) {
        guard let queue = device.makeCommandQueue(), let pipeline = Self.pipeline(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.atlas = atlas
        self.palette = palette
    }

    var metrics: CellMetrics { atlas.metrics }

    func setAtlas(_ atlas: GlyphAtlas) {
        self.atlas = atlas
        backgrounds.removeAll()
        glyphs.removeAll()
    }

    func setPalette(_ palette: RenderPalette) {
        guard palette != self.palette else { return }
        self.palette = palette
        backgrounds.removeAll()
        glyphs.removeAll()
    }

    func invalidate() {
        backgrounds.removeAll()
        glyphs.removeAll()
    }

    static func color(_ color: VTColor, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(color.r) / 255 * alpha, Float(color.g) / 255 * alpha, Float(color.b) / 255 * alpha, alpha)
    }

    func update(screen: VTScreen, dirty: IndexSet) {
        let full = backgrounds.count != screen.rows || atlas.generation != atlasGeneration
        if full {
            backgrounds = Array(repeating: [], count: screen.rows)
            glyphs = Array(repeating: [], count: screen.rows)
        }
        let rows = full ? IndexSet(integersIn: 0..<screen.rows) : dirty
        atlasGeneration = atlas.generation
        for row in rows where row < screen.rows {
            build(row: row, screen: screen)
        }
        if atlas.generation != atlasGeneration {
            update(screen: screen, dirty: IndexSet(integersIn: 0..<screen.rows))
        }
    }

    private func colors(of cell: VTCell, selected: Bool, screen: VTScreen) -> (fg: VTColor, bg: VTColor?) {
        var fg = cell.fg ?? palette.foreground
        var bg = cell.bg
        if cell.flags.contains(.inverse) {
            let swapped = bg ?? palette.background
            bg = fg
            fg = swapped
        }
        if selected {
            return (palette.selectionForeground, palette.selectionBackground)
        }
        return (fg, bg)
    }

    private func build(row: Int, screen: VTScreen) {
        var rowBackgrounds: [RenderInstance] = []
        var rowGlyphs: [RenderInstance] = []
        let cw = Float(metrics.width)
        let ch = Float(metrics.height)
        let y = Float(row) * ch
        let selection = screen.selection[row]
        for col in 0..<screen.cols {
            let cell = screen.cell(col: col, row: row)
            if cell.flags.contains(.spacer) { continue }
            let span = cell.flags.contains(.wide) ? 2 : 1
            let selected = selection?.contains(col) ?? false
            let (fg, bg) = colors(of: cell, selected: selected, screen: screen)
            let x = Float(col) * cw
            if let bg, bg != palette.background || selected {
                rowBackgrounds.append(
                    RenderInstance(rect: SIMD4(x, y, cw * Float(span), ch), color: Self.color(bg)))
            }
            let alpha: Float = cell.flags.contains(.faint) ? 0.5 : 1
            if !cell.isBlank || cell.extra != nil, !cell.flags.contains(.invisible) {
                let key = GlyphKey(
                    scalars: [cell.scalar] + (cell.extra ?? []), bold: cell.flags.contains(.bold),
                    italic: cell.flags.contains(.italic), span: span)
                let entry = atlas.entry(for: key)
                if !entry.empty {
                    rowGlyphs.append(
                        RenderInstance(
                            rect: SIMD4(x, y, Float(entry.width), Float(entry.height)),
                            uv: SIMD4(Float(entry.x), Float(entry.y), Float(entry.width), Float(entry.height)),
                            color: Self.color(fg, alpha: alpha), mode: entry.color ? RenderMode.color : RenderMode.mask)
                    )
                }
            }
            let thickness = Float(metrics.underlineThickness)
            let width = cw * Float(span)
            if cell.flags.contains(.underline) || cell.flags.contains(.curlyUnderline) {
                let lineY = y + ch - Float(metrics.underlinePosition) - thickness
                rowGlyphs.append(
                    RenderInstance(rect: SIMD4(x, lineY, width, thickness), color: Self.color(fg, alpha: alpha)))
            }
            if cell.flags.contains(.doubleUnderline) {
                let lineY = y + ch - Float(metrics.underlinePosition) - thickness
                rowGlyphs.append(
                    RenderInstance(rect: SIMD4(x, lineY, width, thickness), color: Self.color(fg, alpha: alpha)))
                rowGlyphs.append(
                    RenderInstance(
                        rect: SIMD4(x, lineY - thickness * 2, width, thickness), color: Self.color(fg, alpha: alpha)))
            }
            if cell.flags.contains(.strikethrough) {
                rowGlyphs.append(
                    RenderInstance(
                        rect: SIMD4(x, y + (ch * 0.55).rounded(), width, thickness),
                        color: Self.color(fg, alpha: alpha)))
            }
            if cell.flags.contains(.overline) {
                rowGlyphs.append(
                    RenderInstance(rect: SIMD4(x, y, width, thickness), color: Self.color(fg, alpha: alpha)))
            }
        }
        backgrounds[row] = rowBackgrounds
        glyphs[row] = rowGlyphs
    }

    func instances(screen: VTScreen, caret: CaretPaint?, handles: HandlePaint?) -> [RenderInstance] {
        var all: [RenderInstance] = []
        all.reserveCapacity(backgrounds.reduce(0) { $0 + $1.count } + glyphs.reduce(0) { $0 + $1.count } + 8)
        for row in backgrounds { all.append(contentsOf: row) }
        for row in glyphs { all.append(contentsOf: row) }
        let cw = Float(metrics.width)
        let ch = Float(metrics.height)
        if let caret, caret.row >= 0, caret.row < screen.rows, caret.col >= 0, caret.col < screen.cols {
            let cell = screen.cell(col: caret.col, row: caret.row)
            let span: Float = cell.flags.contains(.wide) ? 2 : 1
            let x = Float(caret.col) * cw
            let y = Float(caret.row) * ch
            let color = Self.color(palette.cursor)
            switch caret.style {
            case .block:
                all.append(RenderInstance(rect: SIMD4(x, y, cw * span, ch), color: color))
                if !cell.isBlank || cell.extra != nil {
                    let entry = atlas.entry(
                        for: GlyphKey(
                            scalars: [cell.scalar] + (cell.extra ?? []), bold: cell.flags.contains(.bold),
                            italic: cell.flags.contains(.italic), span: Int(span)))
                    if !entry.empty {
                        let background = cell.bg ?? palette.background
                        all.append(
                            RenderInstance(
                                rect: SIMD4(x, y, Float(entry.width), Float(entry.height)),
                                uv: SIMD4(Float(entry.x), Float(entry.y), Float(entry.width), Float(entry.height)),
                                color: Self.color(background), mode: entry.color ? RenderMode.color : RenderMode.mask))
                    }
                }
            case .hollow:
                let t = Float(max(1, metrics.underlineThickness))
                let w = cw * span
                all.append(RenderInstance(rect: SIMD4(x, y, w, t), color: color))
                all.append(RenderInstance(rect: SIMD4(x, y + ch - t, w, t), color: color))
                all.append(RenderInstance(rect: SIMD4(x, y, t, ch), color: color))
                all.append(RenderInstance(rect: SIMD4(x + w - t, y, t, ch), color: color))
            }
        }
        if let handles {
            let radius = Float(metrics.scale) * 6
            let color = Self.color(palette.handle)
            let startX = Float(handles.start.col) * cw
            let startY = Float(handles.start.row) * ch
            all.append(RenderInstance(rect: SIMD4(startX - 1, startY, 2, ch), color: color))
            all.append(
                RenderInstance(
                    rect: SIMD4(startX - radius, startY - radius * 2, radius * 2, radius * 2), color: color,
                    mode: RenderMode.circle))
            let endX = Float(handles.end.col + 1) * cw
            let endY = Float(handles.end.row + 1) * ch
            all.append(RenderInstance(rect: SIMD4(endX - 1, endY - ch, 2, ch), color: color))
            all.append(
                RenderInstance(
                    rect: SIMD4(endX - radius, endY, radius * 2, radius * 2), color: color, mode: RenderMode.circle))
        }
        return all
    }

    func encode(
        instances: [RenderInstance], into texture: MTLTexture, background: VTColor, yOffset: Float = 0
    ) -> MTLCommandBuffer? {
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.r) / 255, green: Double(background.g) / 255, blue: Double(background.b) / 255,
            alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        lastInstanceCount = instances.count
        if !instances.isEmpty {
            let length = instances.count * MemoryLayout<RenderInstance>.stride
            if let instanceBuffer = claimInstanceBuffer(length: length) {
                let id = ObjectIdentifier(instanceBuffer)
                commandBuffer.addCompletedHandler { [busyBuffers] _ in busyBuffers.release(id) }
                instances.withUnsafeBytes { bytes in
                    instanceBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: length)
                }
                var uniforms = SIMD4<Float>(
                    Float(texture.width), Float(texture.height), Float(atlas.size), yOffset)
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            }
        }
        encoder.endEncoding()
        return commandBuffer
    }

    private func claimInstanceBuffer(length: Int) -> MTLBuffer? {
        if let free = busyBuffers.claim(from: instanceBuffers, length: length) { return free }
        instanceBuffers.removeAll { $0.length < length && !busyBuffers.isBusy($0) }
        guard let buffer = device.makeBuffer(length: max(length, 64 * 1024), options: .storageModeShared) else {
            return nil
        }
        instanceBuffers.append(buffer)
        busyBuffers.mark(buffer)
        return buffer
    }

    nonisolated(unsafe) private static var pipelines: [ObjectIdentifier: MTLRenderPipelineState] = [:]
    private static let pipelinesLock = NSLock()

    private static func pipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let cached = pipelines[ObjectIdentifier(device)] { return cached }
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[ObjectIdentifier(device)] = state
        return state
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Instance {
            float4 rect;
            float4 uv;
            float4 color;
            uint mode;
            uint pad0;
            uint pad1;
            uint pad2;
        };

        struct Out {
            float4 position [[position]];
            float2 uv;
            float2 local;
            float4 color;
            uint mode [[flat]];
        };

        vertex Out terminal_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant Instance *instances [[buffer(0)]],
                                   constant float4 &uniforms [[buffer(1)]]) {
            Instance inst = instances[iid];
            float2 corner = float2(float(vid & 1), float(vid >> 1));
            float2 p = inst.rect.xy + corner * inst.rect.zw;
            p.y += uniforms.w;
            Out out;
            out.position = float4(p.x / uniforms.x * 2.0 - 1.0, 1.0 - p.y / uniforms.y * 2.0, 0.0, 1.0);
            out.uv = (inst.uv.xy + corner * inst.uv.zw) / uniforms.z;
            out.local = corner;
            out.color = inst.color;
            out.mode = inst.mode;
            return out;
        }

        fragment float4 terminal_fragment(Out in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
            constexpr sampler s(filter::nearest);
            if (in.mode == 0) {
                return in.color;
            }
            if (in.mode == 3) {
                float d = length(in.local * 2.0 - 1.0);
                float a = clamp((1.0 - d) * 8.0, 0.0, 1.0);
                return in.color * a;
            }
            float4 t = atlas.sample(s, in.uv);
            if (in.mode == 1) {
                return in.color * t.a;
            }
            return t * in.color.a;
        }
        """
}

private final class BusyBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = Set<ObjectIdentifier>()

    func claim(from buffers: [MTLBuffer], length: Int) -> MTLBuffer? {
        lock.withLock {
            guard let free = buffers.first(where: { $0.length >= length && !busy.contains(ObjectIdentifier($0)) })
            else { return nil }
            busy.insert(ObjectIdentifier(free))
            return free
        }
    }

    func isBusy(_ buffer: MTLBuffer) -> Bool {
        lock.withLock { busy.contains(ObjectIdentifier(buffer)) }
    }

    func mark(_ buffer: MTLBuffer) {
        _ = lock.withLock { busy.insert(ObjectIdentifier(buffer)) }
    }

    func release(_ id: ObjectIdentifier) {
        _ = lock.withLock { busy.remove(id) }
    }
}
