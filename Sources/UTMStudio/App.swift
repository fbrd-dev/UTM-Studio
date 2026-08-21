import SwiftUI
import AppKit

// UTM Studio only ships an arm64 build (see build_app.sh), and this
// compile-time gate is the belt-and-suspenders backstop for that: it means
// there is no code path — however the binary got built or launched — that
// reaches the real app on anything but Apple Silicon. A pure arm64 binary
// already can't launch on an Intel Mac at all (the OS refuses it outright),
// so in practice this branch only ever matters if the build setup changes
// later to produce a universal or x86_64 binary.
#if arch(arm64)

/// Forces a regular (Dock icon + menu bar), frontmost app. Left to its own
/// devices, a SwiftUI app mixing WindowGroup + MenuBarExtra can end up
/// launching as an .accessory-like process with no Dock icon and no active
/// main menu — worse when Xcode runs the raw SwiftPM binary directly instead
/// of through a proper bundled launch. Setting this explicitly, rather than
/// relying on LaunchServices/SwiftUI to infer it, is what actually fixes it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct UTMStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel(settings: AppSettings())

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Client…") {
                    viewModel.pendingNewClientRequest = true
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await viewModel.checkForUpdates(manual: true) }
                }
            }
        }

        MenuBarExtra("UTM Studio", systemImage: "server.rack") {
            MenuBarContent()
                .environmentObject(viewModel)
        }
        .menuBarExtraStyle(.menu)
    }
}

#else

final class UnsupportedAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Fallback app shown instead of the real one when compiled for anything
/// but arm64 — see the note above. Deliberately has no dependency on
/// AppViewModel/AppSettings/UTM at all, so it can never itself be the thing
/// that breaks.
@main
struct UTMStudioUnsupportedApp: App {
    @NSApplicationDelegateAdaptor(UnsupportedAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Apple Silicon Required")
                    .font(.title2.weight(.semibold))
                Text("UTM Studio only supports Apple Silicon Macs. This build was compiled for a different CPU architecture and can't run.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .frame(width: 440, height: 280)
        }
        .windowResizability(.contentSize)
    }
}

#endif
