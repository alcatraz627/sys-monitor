import Foundation
import AppKit
import Darwin

/// On-demand process-detail lookups that are too expensive (or too rarely
/// needed) to run for every PID every tick. Called by the UI when a
/// process row appears — never during the sampling loop.
enum ProcessIntrospection {

    /// Full executable path for a PID, or nil if the process vanished or
    /// the lookup was denied. Path can be hundreds of characters long;
    /// the UI is responsible for truncation.
    static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN (1024). The macro
        // doesn't bridge into Swift, so we hardcode the value.
        let bufferSize = 4 * 1024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let n = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_pidpath(pid, buf.baseAddress, UInt32(bufferSize))
        }
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Best-effort app icon for an executable path. Walks up looking for
    /// the enclosing `.app` bundle and returns that bundle's icon. Returns
    /// nil for raw daemons / CLI binaries / kernel processes — we
    /// deliberately do NOT fall back to a generic terminal icon, because
    /// a sea of identical generics is worse than blank space.
    static func appIcon(for path: String) -> NSImage? {
        var current = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while current.path != "/" && !current.path.isEmpty {
            if current.pathExtension == "app" {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: current.path, isDirectory: &isDir), isDir.boolValue {
                    return NSWorkspace.shared.icon(forFile: current.path)
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }   // root reached
            current = parent
        }
        return nil
    }
}
