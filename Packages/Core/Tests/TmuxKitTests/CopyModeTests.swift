import Foundation
import Testing

@testable import TmuxKit

@Test func copyModeCommandsTargetThePane() {
    #expect(
        Tmux.leaveCopyModeCommand(target: "a'b") == "\(Tmux.tmux) send-keys -t 'a'\\''b' -X cancel 2>/dev/null; true")
    #expect(
        Tmux.historyTopCommand(target: "w-psh-1")
            == "\(Tmux.tmux) copy-mode -e -t 'w-psh-1' \\; send-keys -t 'w-psh-1' -X history-top")
}

#if os(macOS)
    private func hasTmux() -> Bool {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func shell(_ command: String, _ environment: [String: String]) async throws -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        return (
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            process.terminationStatus
        )
    }

    @Test(.enabled(if: hasTmux()))
    func scrolledBackPaneReturnsToTheLiveScreenOnAPrivateServer() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "psh-copy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("tmux"), withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path, "TMUX_TMPDIR": home.appendingPathComponent("tmux").path, "TMPDIR": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        defer {
            let teardown = Process()
            teardown.executableURL = URL(fileURLWithPath: "/bin/sh")
            teardown.arguments = ["-c", "\(Tmux.tmux) kill-server 2>/dev/null; true"]
            teardown.environment = environment
            try? teardown.run()
            while teardown.isRunning { usleep(10_000) }
            try? FileManager.default.removeItem(at: home)
        }
        let target = "base-psh-0000abcd"
        _ = try await shell(
            "\(Tmux.tmux) -f /dev/null new-session -d -s \(target) -x 80 -y 20 'seq 1 300; exec sleep 60'",
            environment)
        func state() async throws -> String {
            try await shell(
                "\(Tmux.tmux) display-message -p -t \(target) '#{pane_in_mode} #{scroll_position} #{history_size}'",
                environment
            ).0
        }
        for _ in 0..<150 {
            if let history = try await state().split(separator: " ").last.flatMap({ Int($0) }), history > 200 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await shell(
            "\(Tmux.tmux) copy-mode -e -t \(target) \\; send-keys -t \(target) -X -N 3 page-up", environment)
        #expect(try await state().hasPrefix("1 "))

        #expect(try await shell(Tmux.leaveCopyModeCommand(target: target), environment).1 == 0)
        #expect(try await state().hasPrefix("0 "))
        #expect(try await shell(Tmux.leaveCopyModeCommand(target: target), environment).1 == 0)
        #expect(try await state().hasPrefix("0 "))

        _ = try await shell(Tmux.historyTopCommand(target: target), environment)
        let top = try await state().split(separator: " ")
        #expect(top.first == "1")
        #expect(top.count == 3 && top[1] == top[2])
        _ = try await shell(Tmux.leaveCopyModeCommand(target: target), environment)
        #expect(try await state().hasPrefix("0 "))
    }
#endif
