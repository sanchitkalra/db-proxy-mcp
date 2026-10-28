import AppKit
import ArgumentParser
import Foundation
import ServiceManagement

/// db-proxy.app is the same binary as the CLI (Contents/MacOS/db-proxy). The background service is
/// an SMAppService agent defined by Contents/Library/LaunchAgents/dev.db-proxy.plist.
enum AppBundle {
    /// The enclosing .app, if this binary runs from one.
    static var url: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    static var service: SMAppService { .agent(plistName: "\(Install.label).plist") }

    /// Registers the background service, replacing a source build's `db-proxy install` plist (same label).
    static func enableService() throws -> String {
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(Install.label).plist")
        if FileManager.default.fileExists(atPath: legacy.path) {
            _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Install.label)"], quiet: true)
            try FileManager.default.removeItem(at: legacy)
        }
        // Always register: `status` can report .enabled for a different job with the same label (e.g. the
        // legacy plist just booted out), and register() is a no-op error when it's genuinely registered.
        do { try service.register() } catch { if service.status != .enabled { throw error } }
        switch service.status {
        case .enabled:
            return "Background service is running (System Settings → General → Login Items)."
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return "Allow db-proxy in System Settings → General → Login Items to start the background service."
        default:
            return "Background service status: \(describe(service.status))."
        }
    }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: "enabled"
        case .requiresApproval: "waiting for approval in System Settings → Login Items"
        case .notRegistered: "not registered"
        case .notFound: "not found (is this the installed app?)"
        @unknown default: "unknown"
        }
    }
}

struct Service: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the background service of db-proxy.app.",
        subcommands: [Enable.self, Disable.self, Status.self])

    static func requireApp() throws {
        guard AppBundle.url != nil else {
            throw ValidationError("`service` only works from db-proxy.app; for a source build use `db-proxy install`")
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register and start the background service.")
        func run() throws { try Service.requireApp(); print(try AppBundle.enableService()) }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and unregister the background service.")
        func run() async throws {
            try Service.requireApp()
            try await AppBundle.service.unregister()
            print("background service disabled")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the background service status.")
        func run() throws {
            try Service.requireApp()
            print("app:     \(AppBundle.url!.path)")
            print("service: \(AppBundle.describe(AppBundle.service.status))")
        }
    }
}

/// Runs when the app is opened from Finder: config, background service, CLI on PATH, next steps.
@MainActor
enum FirstRun {
    static func run() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate()
        guard let app = AppBundle.url else { return }
        guard app.path.hasPrefix("/Applications/") else {
            alert("Move db-proxy to Applications first", "Drag db-proxy.app into the Applications folder, then open it from there.")
            return
        }

        var done: [String] = []
        let configPath = Config.defaultPath
        if !FileManager.default.fileExists(atPath: configPath),
           let example = Bundle.main.url(forResource: "databases.example", withExtension: "toml") {
            try? FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? FileManager.default.copyItem(atPath: example.path, toPath: configPath)
            chmod(configPath, 0o600)
            done.append("Created ~/.config/db-proxy/databases.toml from the example.")
        }

        do { done.append(try AppBundle.enableService()) } catch {
            done.append("Could not start the background service: \(error.localizedDescription)")
        }

        done.append(installCLIWrapper(app: app))

        let next = """
            Next, in Terminal:
              1. Edit ~/.config/db-proxy/databases.toml
              2. db-proxy password set <server>/<user>
              3. db-proxy agent add claude     (or cursor, codex)
              4. db-proxy check
            After editing the config: launchctl kickstart -k gui/$(id -u)/\(Install.label)
            """
        let a = NSAlert()
        a.messageText = "db-proxy is installed"
        a.informativeText = done.joined(separator: "\n") + "\n\n" + next
        a.addButton(withTitle: "Open Config")
        a.addButton(withTitle: "Done")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(filePath: configPath))
        }
    }

    /// /usr/local/bin/db-proxy as a tiny exec wrapper (not a symlink, so the binary still finds its bundle).
    private static func installCLIWrapper(app: URL) -> String {
        let target = "/usr/local/bin/db-proxy"
        let exe = app.appending(path: "Contents/MacOS/db-proxy").path
        let script = "#!/bin/sh\nexec '\(exe)' \"$@\"\n"
        if (try? String(contentsOfFile: target, encoding: .utf8)) == script { return "`db-proxy` is on your PATH." }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "db-proxy-wrapper").path
        guard (try? script.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return "Could not add `db-proxy` to PATH." }
        let source = """
            do shell script "mkdir -p /usr/local/bin && install -m 755 " & quoted form of "\(tmp)" & " \(target)" \
            with prompt "db-proxy wants to add the db-proxy command to /usr/local/bin." with administrator privileges
            """
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        try? FileManager.default.removeItem(atPath: tmp)
        return err == nil ? "Added `db-proxy` to /usr/local/bin." : "Skipped adding `db-proxy` to PATH; use \(exe)."
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
