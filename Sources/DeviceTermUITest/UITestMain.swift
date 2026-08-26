// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// The process entry logic (side effects live here).
///
/// `run` parses argv, then either serves the resident harness or performs
/// one client request. Kept out of `main.swift` so the top-level file is
/// a single call and this logic stays greppable.
enum UITestMain {
    @MainActor
    static func run(args: [String]) -> Never {
        let command: UITestCommand
        do {
            command = try UITestCLI.parse(args)
        } catch let error as UITestParseError {
            printErr(error.message + "\n\n" + UITestCLI.usageText)
            exit(2)
        } catch {
            printErr("deviceterm-uitest: \(error)")
            exit(2)
        }

        switch command {
        case .usage:
            print(UITestCLI.usageText)
            exit(0)

        case .serve:
            runResident()

        case let .client(request):
            runClient(request)
        }
    }

    @MainActor
    private static func runResident() -> Never {
        let path = UITestPaths.socketPath
        do {
            try UITestPaths.ensureParentDirectory()
            let server = ResidentServer(socketPath: path)
            try server.start()
            printErr("deviceterm-uitest: resident listening on \(path)")
        } catch {
            printErr("deviceterm-uitest: failed to start resident: \(error)")
            exit(1)
        }

        // Prompt for anything missing. Beyond the prompt itself, this is
        // what registers the harness in the System Settings privacy lists:
        // an app that never asks never appears there to be ticked.
        TCCStatus.requestMissingGrants()

        // An accessory NSApplication gives the main thread a run loop with
        // no Dock icon or menu: it keeps the resident alive, and satisfies
        // LaunchServices when this runs as a faceless .app. The accept loop
        // keeps running on its background queue.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)  // `run()` does not return; this satisfies `Never`.
    }

    private static func runClient(_ request: UITestRequest) -> Never {
        let path = UITestPaths.socketPath
        do {
            let reply = try UITestClient.send(request, socketPath: path)
            FileHandle.standardOutput.write(reply.json)
            FileHandle.standardOutput.write(Data("\n".utf8))
            // Machine-readable diagnosis on stdout; the human fix on stderr.
            if request.method == .doctor, !reply.ok {
                printErr(remediation(forDoctor: reply.json))
            }
            exit(reply.ok ? 0 : 1)
        } catch UITestClientError.notRunning {
            // Deliberately not `deviceterm-uitest serve`: run from a shell,
            // the harness's TCC grants attribute to the terminal. Only
            // `make uitest-run` launches the bundled .app through
            // LaunchServices, where it owns its own identity.
            printErr(
                "deviceterm-uitest: no resident harness at \(path). "
                    + "start one with `make uitest-run`."
            )
            exit(3)
        } catch {
            printErr("deviceterm-uitest: \(error)")
            exit(1)
        }
    }

    /// Turn a failing `doctor` reply into the exact steps that fix it.
    /// The grants belong to the *resident's* bundle, so its own reported
    /// path is what the user must tick in System Settings.
    static func remediation(forDoctor json: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        let bundlePath = object?["bundlePath"] as? String ?? "the resident harness"
        let hasScreenRecording = object?["screenRecording"] as? Bool ?? false
        let hasAccessibility = object?["accessibility"] as? Bool ?? false

        var lines = [
            "deviceterm-uitest: the resident harness is missing privacy grants.",
            "Grant them to this bundle (not to deviceterm, and not to your terminal):",
            "  \(bundlePath)",
            "In System Settings → Privacy & Security, enable it under:"
        ]
        if !hasScreenRecording { lines.append("  • Screen Recording") }
        if !hasAccessibility { lines.append("  • Accessibility") }
        lines.append("Then restart it with `make uitest-run` and re-run `deviceterm-uitest doctor`.")
        return lines.joined(separator: "\n")
    }

    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
