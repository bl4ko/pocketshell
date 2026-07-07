import Foundation
import SFTPKit
import Testing

@Test func initPacketEncodesVersion3() {
    let data = SFTPPacket.initPacket()
    #expect(Array(data) == [0, 0, 0, 5, 1, 0, 0, 0, 3])
}

@Test func openDirEncodesIdAndPath() {
    let data = SFTPPacket.openDir(id: 7, path: "/tmp")
    var expected: [UInt8] = [0, 0, 0, 13, 11]
    expected += [0, 0, 0, 7]
    expected += [0, 0, 0, 4] + Array("/tmp".utf8)
    #expect(Array(data) == expected)
}

@Test func readPacketEncodesHandleOffsetLength() {
    let handle = Data([0xaa, 0xbb])
    let data = SFTPPacket.read(id: 2, handle: handle, offset: 0x0102, length: 0x8000)
    var expected: [UInt8] = [0, 0, 0, 23, 5]
    expected += [0, 0, 0, 2]
    expected += [0, 0, 0, 2, 0xaa, 0xbb]
    expected += [0, 0, 0, 0, 0, 0, 1, 2]
    expected += [0, 0, 0x80, 0]
    #expect(Array(data) == expected)
}

@Test func openReadEncodesPflagsAndEmptyAttrs() {
    let data = SFTPPacket.openRead(id: 1, path: "a")
    var expected: [UInt8] = [0, 0, 0, 18, 3]
    expected += [0, 0, 0, 1]
    expected += [0, 0, 0, 1] + Array("a".utf8)
    expected += [0, 0, 0, 1]
    expected += [0, 0, 0, 0]
    #expect(Array(data) == expected)
}

private func packet(_ type: UInt8, _ payload: [UInt8]) -> Data {
    var data = Data()
    let length = UInt32(payload.count + 1)
    data.append(contentsOf: [
        UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff),
        UInt8(length >> 8 & 0xff), UInt8(length & 0xff),
    ])
    data.append(type)
    data.append(contentsOf: payload)
    return data
}

private func u32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
}

private func str(_ value: String) -> [UInt8] {
    u32(UInt32(value.utf8.count)) + Array(value.utf8)
}

@Test func parseVersionResponse() {
    var framing = SFTPFraming()
    let responses = framing.append(packet(2, u32(3)))
    #expect(responses == [.version(3)])
}

@Test func parseStatusResponse() {
    var framing = SFTPFraming()
    let payload = u32(9) + u32(1) + str("End of file") + str("en")
    let responses = framing.append(packet(101, payload))
    #expect(responses == [.status(id: 9, code: 1, message: "End of file")])
}

@Test func parseHandleResponse() {
    var framing = SFTPFraming()
    let payload = u32(4) + u32(3) + [1, 2, 3]
    let responses = framing.append(packet(102, payload))
    #expect(responses == [.handle(id: 4, handle: Data([1, 2, 3]))])
}

@Test func parseDataResponse() {
    var framing = SFTPFraming()
    let payload = u32(5) + u32(2) + [0xde, 0xad]
    let responses = framing.append(packet(103, payload))
    #expect(responses == [.data(id: 5, payload: Data([0xde, 0xad]))])
}

@Test func parseNameResponseWithAttrs() {
    var framing = SFTPFraming()
    var payload = u32(6) + u32(2)
    payload += str("docs") + str("drwxr-xr-x docs")
    payload += u32(0x0000_0005) + [0, 0, 0, 0, 0, 0, 0, 100] + u32(0o040755)
    payload += str("file.txt") + str("-rw-r--r-- file.txt")
    payload += u32(0x0000_0005) + [0, 0, 0, 0, 0, 0, 2, 0] + u32(0o100644)
    let responses = framing.append(packet(104, payload))
    guard case .name(let id, let entries)? = responses.first else {
        Issue.record("expected name response")
        return
    }
    #expect(id == 6)
    #expect(entries.count == 2)
    #expect(entries[0].filename == "docs")
    #expect(entries[0].attributes.isDirectory)
    #expect(entries[0].attributes.size == 100)
    #expect(entries[1].filename == "file.txt")
    #expect(!entries[1].attributes.isDirectory)
    #expect(entries[1].attributes.size == 512)
}

@Test func framingHandlesSplitPackets() {
    var framing = SFTPFraming()
    let full = packet(2, u32(3)) + packet(101, u32(1) + u32(0) + str("ok") + str(""))
    let mid = full.count / 2
    let first = framing.append(full.prefix(mid))
    let second = framing.append(full.suffix(from: mid))
    #expect(first.count + second.count == 2)
}

@Test func framingIgnoresUnknownPacketTypes() {
    var framing = SFTPFraming()
    let responses = framing.append(packet(200, [1, 2, 3]) + packet(2, u32(3)))
    #expect(responses == [.version(3)])
}
