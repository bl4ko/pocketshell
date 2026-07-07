import Foundation
import NIOCore
import NIOSSH
import SFTPKit

public enum SFTPError: Error, Equatable, Sendable {
    case protocolError(String)
    case status(code: UInt32, message: String)
    case closed
}

public actor SFTPSession {
    private let channel: Channel
    private var framing = SFTPFraming()
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var versionContinuation: CheckedContinuation<Void, Error>?
    private var nextID: UInt32 = 0
    private var readerTask: Task<Void, Never>?

    init(channel: Channel) {
        self.channel = channel
    }

    func start(chunks: AsyncStream<Data>) async throws {
        readerTask = Task { [weak self] in
            for await chunk in chunks {
                await self?.consume(chunk)
            }
            await self?.streamEnded()
        }
        try await handshake()
    }

    private func handshake() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            versionContinuation = continuation
            send(SFTPPacket.initPacket())
        }
    }

    public func realPath(_ path: String) async throws -> String {
        let response = try await request { SFTPPacket.realPath(id: $0, path: path) }
        guard case .name(_, let entries) = response, let first = entries.first else {
            throw try Self.unexpected(response)
        }
        return first.filename
    }

    public func listDirectory(_ path: String) async throws -> [SFTPName] {
        let handle = try await openDirHandle(path)
        defer { Task { try? await self.closeHandle(handle) } }
        var entries: [SFTPName] = []
        while true {
            let response = try await request { SFTPPacket.readDir(id: $0, handle: handle) }
            switch response {
            case .name(_, let batch):
                entries.append(contentsOf: batch)
            case .status(_, SFTPStatusCode.eof, _):
                return entries.filter { $0.filename != "." && $0.filename != ".." }
            default:
                throw try Self.unexpected(response)
            }
        }
    }

    public func download(_ path: String) async throws -> Data {
        let response = try await request { SFTPPacket.openRead(id: $0, path: path) }
        guard case .handle(_, let handle) = response else {
            throw try Self.unexpected(response)
        }
        defer { Task { try? await self.closeHandle(handle) } }
        var data = Data()
        while true {
            let chunk = try await request {
                SFTPPacket.read(id: $0, handle: handle, offset: UInt64(data.count), length: 32768)
            }
            switch chunk {
            case .data(_, let payload):
                data.append(payload)
            case .status(_, SFTPStatusCode.eof, _):
                return data
            default:
                throw try Self.unexpected(chunk)
            }
        }
    }

    public func close() async {
        readerTask?.cancel()
        try? await channel.close()
        for continuation in pending.values {
            continuation.resume(throwing: SFTPError.closed)
        }
        pending = [:]
    }

    private func openDirHandle(_ path: String) async throws -> Data {
        let response = try await request { SFTPPacket.openDir(id: $0, path: path) }
        guard case .handle(_, let handle) = response else {
            throw try Self.unexpected(response)
        }
        return handle
    }

    private func closeHandle(_ handle: Data) async throws {
        _ = try await request { SFTPPacket.close(id: $0, handle: handle) }
    }

    private func request(_ build: (UInt32) -> Data) async throws -> SFTPResponse {
        nextID &+= 1
        let id = nextID
        let packet = build(id)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(packet)
        }
    }

    private func send(_ data: Data) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
            .whenFailure { [weak self] error in
                Task { await self?.failAll(error) }
            }
    }

    private func consume(_ chunk: Data) {
        for response in framing.append(chunk) {
            dispatch(response)
        }
    }

    private func dispatch(_ response: SFTPResponse) {
        switch response {
        case .version:
            versionContinuation?.resume()
            versionContinuation = nil
        case .status(let id, let code, let message):
            if code != SFTPStatusCode.ok, code != SFTPStatusCode.eof {
                pending.removeValue(forKey: id)?
                    .resume(throwing: SFTPError.status(code: code, message: message))
            } else {
                pending.removeValue(forKey: id)?.resume(returning: response)
            }
        case .handle(let id, _), .data(let id, _), .name(let id, _):
            pending.removeValue(forKey: id)?.resume(returning: response)
        }
    }

    private func streamEnded() {
        failAll(SFTPError.closed)
    }

    private func failAll(_ error: Error) {
        versionContinuation?.resume(throwing: error)
        versionContinuation = nil
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending = [:]
    }

    private static func unexpected(_ response: SFTPResponse) throws -> SFTPError {
        if case .status(_, let code, let message) = response {
            return SFTPError.status(code: code, message: message)
        }
        return SFTPError.protocolError("\(response)")
    }
}

extension SSHConnection {
    public func openSFTP() async throws -> SFTPSession {
        var continuation: AsyncStream<Data>.Continuation!
        let chunks = AsyncStream<Data> { continuation = $0 }
        let dataHandler = ShellDataHandler(continuation: continuation)

        let childChannel = try await createChildChannel { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(dataHandler)
            }
        }
        try await childChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        )
        let session = SFTPSession(channel: childChannel)
        try await session.start(chunks: chunks)
        return session
    }
}
