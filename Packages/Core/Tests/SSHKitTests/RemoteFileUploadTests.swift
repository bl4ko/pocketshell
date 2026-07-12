import Foundation
import SSHKit
import Testing

@Test func smallPayloadProducesWriteAndDecode() {
    let commands = RemoteFileUpload.commands(base64: "aGVsbG8=", remotePath: "/tmp/psh-x.jpg", chunkSize: 100)
    #expect(commands == [
        "printf '%s' 'aGVsbG8=' > '/tmp/psh-x.jpg.b64'",
        "base64 -d '/tmp/psh-x.jpg.b64' > '/tmp/psh-x.jpg' && rm '/tmp/psh-x.jpg.b64'",
    ])
}

@Test func largePayloadAppendsChunks() {
    let commands = RemoteFileUpload.commands(base64: "AAAABBBBCC", remotePath: "/tmp/f.png", chunkSize: 4)
    #expect(commands == [
        "printf '%s' 'AAAA' > '/tmp/f.png.b64'",
        "printf '%s' 'BBBB' >> '/tmp/f.png.b64'",
        "printf '%s' 'CC' >> '/tmp/f.png.b64'",
        "base64 -d '/tmp/f.png.b64' > '/tmp/f.png' && rm '/tmp/f.png.b64'",
    ])
}

@Test func remotePathGeneratesUniqueJpgUnderTmp() {
    let path = RemoteFileUpload.remotePath()
    #expect(path.hasPrefix("/tmp/psh-"))
    #expect(path.hasSuffix(".jpg"))
    #expect(path != RemoteFileUpload.remotePath())
}
