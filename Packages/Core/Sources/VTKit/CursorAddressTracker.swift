public struct CursorAddressTracker: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case string
    }

    public private(set) var addressed = false
    public private(set) var sawHide = false
    private var state = State.ground
    private var privateMarker = false
    private var intermediate = false
    private var params: [UInt8] = []

    public init() {}

    public mutating func beginChunk() {
        sawHide = false
    }

    public mutating func scan(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes {
            step(byte)
        }
    }

    public mutating func scan(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { scan($0) }
    }

    private mutating func step(_ byte: UInt8) {
        if byte == 0x18 || byte == 0x1a {
            state = .ground
            return
        }
        if byte == 0x1b {
            state = .escape
            return
        }
        switch state {
        case .ground:
            if byte >= 0x20 || (0x08...0x0d).contains(byte) {
                addressed = false
            }
        case .escape:
            switch byte {
            case 0x5b:
                state = .csi
                privateMarker = false
                intermediate = false
                params.removeAll(keepingCapacity: true)
            case 0x5d, 0x50, 0x5f, 0x5e, 0x58:
                state = .string
            case 0x20...0x2f:
                state = .escapeIntermediate
            case 0x44, 0x45, 0x4d, 0x38:
                addressed = false
                state = .ground
            case 0x00...0x1f:
                control(byte)
            default:
                state = .ground
            }
        case .escapeIntermediate:
            if byte < 0x20 {
                control(byte)
            } else if byte >= 0x30 {
                state = .ground
            }
        case .csi:
            switch byte {
            case 0x00...0x1f:
                control(byte)
            case 0x3c...0x3f:
                privateMarker = true
            case 0x30...0x3b:
                if params.count < 16 { params.append(byte) }
            case 0x20...0x2f:
                intermediate = true
            case 0x40...0x7e:
                dispatch(byte)
                state = .ground
            default:
                state = .ground
            }
        case .string:
            if byte == 0x07 {
                state = .ground
            }
        }
    }

    private mutating func control(_ byte: UInt8) {
        if (0x08...0x0d).contains(byte) {
            addressed = false
        }
    }

    private mutating func dispatch(_ final: UInt8) {
        if privateMarker {
            if !intermediate, final == 0x6c,
                params.split(separator: 0x3b).contains(where: { Array($0) == [0x32, 0x35] })
            {
                sawHide = true
            }
            return
        }
        guard !intermediate else { return }
        switch final {
        case 0x48, 0x66:
            addressed = true
        case 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x60, 0x61, 0x64, 0x65, 0x49, 0x5a, 0x6a, 0x6b, 0x75:
            addressed = false
        default:
            break
        }
    }
}
