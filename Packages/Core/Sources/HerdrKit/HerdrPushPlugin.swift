import Foundation

public enum HerdrPushPlugin {
    public static let directory = "$HOME/.local/share/pocketshell/herdr-push"

    public static func installCommands(endpoint: URL, hostID: UUID, secret: String) -> [String] {
        let config = """
            \(endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            \(hostID.uuidString.lowercased())
            \(secret)

            """
        return [
            "mkdir -p \"\(directory)\" && chmod 700 \"\(directory)\"",
            writeCommand(manifest, to: "herdr-plugin.toml", mode: "600"),
            writeCommand(script, to: "push.sh", mode: "700"),
            writeCommand(config, to: "config", mode: "600"),
        ]
    }

    public static func linkCommand(session: String) -> String {
        "\(Herdr.commandPrefix(session: session)) plugin link \"\(directory)\" --enabled"
    }

    private static func writeCommand(_ contents: String, to name: String, mode: String) -> String {
        let base64 = Data(contents.utf8).base64EncodedString()
        return
            "printf '%s' '\(base64)' | base64 -d > \"\(directory)/\(name)\" && chmod \(mode) \"\(directory)/\(name)\""
    }

    private static let manifest = """
        id = "com.bl4ko.pocketshell.push"
        name = "PocketShell Push"
        version = "0.1.0"
        min_herdr_version = "0.8.0"
        description = "Send semantic agent alerts to PocketShell"
        platforms = ["linux", "macos"]

        [[events]]
        on = "pane.agent_status_changed"
        command = ["sh", "push.sh"]

        """

    private static let script = """
        #!/bin/sh
        set -eu

        {
            IFS= read -r endpoint
            IFS= read -r host_id
            IFS= read -r secret
        } < "$HERDR_PLUGIN_ROOT/config"

        case "${HERDR_SOCKET_PATH:-}" in
            */sessions/*/herdr.sock)
                session=${HERDR_SOCKET_PATH%/herdr.sock}
                session=${session##*/}
                ;;
            *) session=default ;;
        esac
        case "$session" in *[!A-Za-z0-9._-]*) session=default ;; esac

        curl --fail --silent --show-error --retry 3 --retry-delay 1 --connect-timeout 5 --max-time 20 \
            -X POST "$endpoint/v1/hosts/$host_id/events" \
            -H "Authorization: Bearer $secret" \
            -H "Content-Type: application/json" \
            -H "X-Herdr-Session: $session" \
            --data-binary "$HERDR_PLUGIN_EVENT_JSON"

        """
}
