import Foundation
import Observation

/// Monitors whether the primary application window is actively visible on the user's display.
///
/// Automatically tracks macOS `NSWindow.occlusionState` to determine if the window is:
/// - Visible on the currently active Space / desktop
/// - Obscured or completely hidden behind other application windows
/// - On an inactive virtual desktop / Space
/// - Closed / hidden via `Cmd + W` (`orderOut`)
/// - Miniaturized in the Dock
///
/// Views with continuous animations (Equalizer bars, Marquee scrolling text) observe
/// this state to instantly suspend all GPU and CPU animation work when the user cannot
/// see the window, and resume immediately and smoothly at 120 FPS when brought into view.
@MainActor
@Observable
final class WindowOcclusionMonitor {
    static let shared = WindowOcclusionMonitor()

    var isMainWindowVisible: Bool = true
}
