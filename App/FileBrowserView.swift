import QuickLook
import SFTPKit
import SSHKit
import SwiftUI

struct FileBrowserView: View {
    @State private var sftp: SFTPSession?
    @State private var path = "."
    @State private var entries: [SFTPName] = []
    @State private var loading = true
    @State private var downloading: String?
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    let controller: ConnectionController?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if path != "/" {
                    Button {
                        navigate(to: parentPath)
                    } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(sorted, id: \.filename) { entry in
                    row(entry)
                }
            }
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if loading {
                    ProgressView()
                }
            }
            .task {
                await open()
            }
            .onDisappear {
                let sftp = sftp
                Task { await sftp?.close() }
            }
            .quickLookPreview($previewURL)
            .themedScreen()
        }
    }

    private var sorted: [SFTPName] {
        entries.sorted {
            if $0.attributes.isDirectory != $1.attributes.isDirectory {
                return $0.attributes.isDirectory
            }
            return $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
    }

    private var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func row(_ entry: SFTPName) -> some View {
        Button {
            if entry.attributes.isDirectory {
                navigate(to: (path as NSString).appendingPathComponent(entry.filename))
            } else {
                download(entry)
            }
        } label: {
            HStack {
                Image(systemName: entry.attributes.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.attributes.isDirectory ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.filename)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !entry.attributes.isDirectory, let size = entry.attributes.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if downloading == entry.filename {
                    ProgressView()
                }
            }
        }
        .disabled(downloading != nil)
    }

    private func open() async {
        guard let controller else {
            errorMessage = "no active connection"
            loading = false
            return
        }
        do {
            let session = try await controller.openSFTP()
            sftp = session
            path = try await session.realPath(".")
            await refresh()
        } catch {
            errorMessage = "\(error)"
            loading = false
        }
    }

    private func navigate(to newPath: String) {
        path = newPath
        Task { await refresh() }
    }

    private func refresh() async {
        guard let sftp else { return }
        loading = true
        errorMessage = nil
        do {
            entries = try await sftp.listDirectory(path)
        } catch {
            errorMessage = "\(error)"
        }
        loading = false
    }

    private func download(_ entry: SFTPName) {
        guard let sftp else { return }
        downloading = entry.filename
        let remotePath = (path as NSString).appendingPathComponent(entry.filename)
        Task {
            defer { downloading = nil }
            do {
                let data = try await sftp.download(remotePath)
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sftp-downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let local = dir.appendingPathComponent(entry.filename)
                try data.write(to: local, options: .atomic)
                previewURL = local
            } catch {
                errorMessage = "\(error)"
            }
        }
    }
}
