import Foundation

public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var permissions: UInt32?

    public var isDirectory: Bool {
        guard let permissions else { return false }
        return permissions & 0o170000 == 0o040000
    }

    public init(size: UInt64? = nil, permissions: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
    }
}

public struct SFTPName: Equatable, Sendable {
    public let filename: String
    public let longname: String
    public let attributes: SFTPAttributes
}

public enum SFTPResponse: Equatable, Sendable {
    case version(UInt32)
    case status(id: UInt32, code: UInt32, message: String)
    case handle(id: UInt32, handle: Data)
    case data(id: UInt32, payload: Data)
    case name(id: UInt32, entries: [SFTPName])
}

public enum SFTPStatusCode {
    public static let ok: UInt32 = 0
    public static let eof: UInt32 = 1
}

public enum SFTPPacket {
    static let typeInit: UInt8 = 1
    static let typeOpen: UInt8 = 3
    static let typeClose: UInt8 = 4
    static let typeRead: UInt8 = 5
    static let typeOpenDir: UInt8 = 11
    static let typeReadDir: UInt8 = 12
    static let typeRealPath: UInt8 = 16
    static let typeVersion: UInt8 = 2
    static let typeStatus: UInt8 = 101
    static let typeHandle: UInt8 = 102
    static let typeData: UInt8 = 103
    static let typeName: UInt8 = 104

    public static func initPacket(version: UInt32 = 3) -> Data {
        frame(typeInit) { $0.appendU32(version) }
    }

    public static func openDir(id: UInt32, path: String) -> Data {
        frame(typeOpenDir) {
            $0.appendU32(id)
            $0.appendSFTPString(path)
        }
    }

    public static func readDir(id: UInt32, handle: Data) -> Data {
        frame(typeReadDir) {
            $0.appendU32(id)
            $0.appendSFTPData(handle)
        }
    }

    public static func close(id: UInt32, handle: Data) -> Data {
        frame(typeClose) {
            $0.appendU32(id)
            $0.appendSFTPData(handle)
        }
    }

    public static func openRead(id: UInt32, path: String) -> Data {
        frame(typeOpen) {
            $0.appendU32(id)
            $0.appendSFTPString(path)
            $0.appendU32(1)
            $0.appendU32(0)
        }
    }

    public static func read(id: UInt32, handle: Data, offset: UInt64, length: UInt32) -> Data {
        frame(typeRead) {
            $0.appendU32(id)
            $0.appendSFTPData(handle)
            $0.appendU64(offset)
            $0.appendU32(length)
        }
    }

    public static func realPath(id: UInt32, path: String) -> Data {
        frame(typeRealPath) {
            $0.appendU32(id)
            $0.appendSFTPString(path)
        }
    }

    private static func frame(_ type: UInt8, _ build: (inout Data) -> Void) -> Data {
        var payload = Data()
        build(&payload)
        var data = Data()
        data.appendU32(UInt32(payload.count + 1))
        data.append(type)
        data.append(payload)
        return data
    }
}

public struct SFTPFraming: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [SFTPResponse] {
        buffer.append(chunk)
        var responses: [SFTPResponse] = []
        while buffer.count >= 4 {
            let length = Int(buffer.readU32(at: buffer.startIndex))
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            let packet = buffer.subdata(in: start..<(start + length))
            buffer.removeFirst(4 + length)
            if let response = Self.parse(packet) {
                responses.append(response)
            }
        }
        return responses
    }

    private static func parse(_ packet: Data) -> SFTPResponse? {
        var reader = SFTPReader(packet)
        guard let type = reader.readByte() else { return nil }
        switch type {
        case SFTPPacket.typeVersion:
            guard let version = reader.readU32() else { return nil }
            return .version(version)
        case SFTPPacket.typeStatus:
            guard let id = reader.readU32(), let code = reader.readU32() else { return nil }
            let message = reader.readString() ?? ""
            return .status(id: id, code: code, message: message)
        case SFTPPacket.typeHandle:
            guard let id = reader.readU32(), let handle = reader.readData() else { return nil }
            return .handle(id: id, handle: handle)
        case SFTPPacket.typeData:
            guard let id = reader.readU32(), let payload = reader.readData() else { return nil }
            return .data(id: id, payload: payload)
        case SFTPPacket.typeName:
            guard let id = reader.readU32(), let count = reader.readU32() else { return nil }
            var entries: [SFTPName] = []
            for _ in 0..<count {
                guard let filename = reader.readString(),
                      let longname = reader.readString(),
                      let attrs = reader.readAttributes()
                else { return nil }
                entries.append(SFTPName(filename: filename, longname: longname, attributes: attrs))
            }
            return .name(id: id, entries: entries)
        default:
            return nil
        }
    }
}

struct SFTPReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func readByte() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readU32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        defer { offset += 4 }
        return data.readU32(at: offset)
    }

    mutating func readU64() -> UInt64? {
        guard let high = readU32(), let low = readU32() else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func readData() -> Data? {
        guard let length = readU32(), offset + Int(length) <= data.endIndex else { return nil }
        defer { offset += Int(length) }
        return data.subdata(in: offset..<(offset + Int(length)))
    }

    mutating func readString() -> String? {
        guard let bytes = readData() else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    mutating func readAttributes() -> SFTPAttributes? {
        guard let flags = readU32() else { return nil }
        var attrs = SFTPAttributes()
        if flags & 0x1 != 0 {
            attrs.size = readU64()
        }
        if flags & 0x2 != 0 {
            _ = readU32()
            _ = readU32()
        }
        if flags & 0x4 != 0 {
            attrs.permissions = readU32()
        }
        if flags & 0x8 != 0 {
            _ = readU32()
            _ = readU32()
        }
        return attrs
    }
}

extension Data {
    mutating func appendU32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
            UInt8(value >> 8 & 0xff), UInt8(value & 0xff),
        ])
    }

    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32(value >> 32))
        appendU32(UInt32(value & 0xffff_ffff))
    }

    mutating func appendSFTPString(_ value: String) {
        appendSFTPData(Data(value.utf8))
    }

    mutating func appendSFTPData(_ value: Data) {
        appendU32(UInt32(value.count))
        append(value)
    }

    func readU32(at index: Index) -> UInt32 {
        UInt32(self[index]) << 24
            | UInt32(self[index + 1]) << 16
            | UInt32(self[index + 2]) << 8
            | UInt32(self[index + 3])
    }
}
