import AppKit
import AVFoundation

/// Microphone permission, asked for *before* anything is recorded, never in
/// the middle of it. The engine records in a child process of this app, so
/// the grant made here is the one that covers it.
enum MicAccess {
    enum State { case granted, denied }

    static func ensure() async -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        default:
            return .denied
        }
    }

    static let deniedMessage = "Sayso doesn't have microphone access. Allow it in "
        + "System Settings > Privacy & Security > Microphone, then try again."

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
