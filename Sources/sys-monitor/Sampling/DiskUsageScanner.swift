import Foundation

/// Finds which folders in the home directory are using the disk, so a nearly
/// full drive comes with somewhere to look.
///
/// A scan measures each top-level folder in turn with `du` and publishes the
/// running result, largest first, so the big ones show up as they are found.
/// It runs only when asked, at low priority, and a finished scan is reused for
/// fifteen minutes: measuring a home folder reads every file's metadata, which
/// can take minutes and is not something to repeat on every panel open.
///
/// macOS asks the user before an app may look inside Desktop, Documents and
/// Downloads. A folder the user declines is left out of the result.
@MainActor
final class DiskUsageScanner: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let path: String
        let name: String
        let bytes: UInt64
        var id: String { path }
    }

    @Published private(set) var entries: [Entry] = []
    /// Name of the folder being measured, or nil when no scan is running.
    @Published private(set) var scanning: String?
    @Published private(set) var finishedAt: Date?

    private var generation = 0
    private let running = RunningProcess()
    private let queue = DispatchQueue(label: "sys-monitor.disk-usage", qos: .utility)

    /// Set by the render probe so a picture of the panel shows fixed folders
    /// and never starts a real scan of the home directory.
    static var fixture: [Entry]?

    /// Start a scan unless one is running or a recent one can be reused.
    func scanIfStale(maxAge: TimeInterval = 15 * 60) {
        if let fixture = Self.fixture {
            entries = fixture
            finishedAt = Date()
            return
        }
        if scanning != nil { return }
        if let done = finishedAt, Date().timeIntervalSince(done) < maxAge { return }
        generation += 1
        let gen = generation
        entries = []
        finishedAt = nil
        scanning = "home"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let running = self.running
        queue.async { [weak self] in
            for folder in Self.topLevelFolders(of: home) {
                let stillWanted = DispatchQueue.main.sync { [weak self] () -> Bool in
                    guard let self, self.generation == gen else { return false }
                    self.scanning = folder.lastPathComponent
                    return true
                }
                guard stillWanted else { return }
                guard let bytes = Self.measure(folder, holder: running), bytes > 0 else { continue }
                let entry = Entry(path: folder.path, name: folder.lastPathComponent, bytes: bytes)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.entries = (self.entries + [entry]).sorted { $0.bytes > $1.bytes }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.scanning = nil
                self.finishedAt = Date()
            }
        }
    }

    /// Stop a scan in progress. What it found so far is kept on screen, and
    /// the next request starts again from the beginning.
    func cancel() {
        guard scanning != nil else { return }
        generation += 1
        scanning = nil
        running.terminate()
    }

    /// The home directory's own folders, hidden ones included, since caches
    /// and package stores live in dot-folders. Symlinks are skipped so a
    /// linked volume is not counted as part of home.
    nonisolated static func topLevelFolders(of home: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: keys, options: [])) ?? []
        return children.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }
    }

    /// Bytes a folder occupies on disk, or nil if it could not be measured.
    nonisolated static func measure(_ folder: URL, holder: RunningProcess) -> UInt64? {
        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        // -k reports kilobytes; -x stays on this volume.
        du.arguments = ["-skx", folder.path]
        let out = Pipe()
        du.standardOutput = out
        du.standardError = FileHandle.nullDevice
        do { try du.run() } catch { return nil }
        holder.set(du)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        du.waitUntilExit()
        holder.set(nil)
        // du exits non-zero when it could not read part of a folder but still
        // prints what it measured, so the output decides, not the status.
        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// Read the size from one line of `du -sk` output: kilobytes, a tab, the path.
    nonisolated static func parse(_ line: String) -> UInt64? {
        guard let first = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kb = UInt64(first) else { return nil }
        return kb * 1024
    }
}

/// Holds the `du` process a scan is waiting on, so a cancel from the main
/// thread can stop it.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ p: Process?) {
        lock.lock(); process = p; lock.unlock()
    }

    func terminate() {
        lock.lock(); let p = process; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }
}
