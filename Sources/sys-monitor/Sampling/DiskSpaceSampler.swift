import Foundation

/// Free and total space on a mounted volume, via a single `statfs` syscall.
/// Defaults to the boot volume ("/"). Cheap enough to read live each panel
/// sweep — and it MUST be read live, not cached: free space changes out of
/// band as every other process writes the disk, so a TTL would surface a
/// stale number.
struct DiskSpaceSampler {
    func read(path: String = "/") -> DiskSpaceSample? {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return nil }
        let block = UInt64(buf.f_bsize)
        // f_bavail = blocks available to a non-root process — the honest
        // "what you can actually use," which is what the user expects.
        let free  = UInt64(buf.f_bavail) * block
        let total = UInt64(buf.f_blocks) * block
        guard total > 0 else { return nil }
        return DiskSpaceSample(freeBytes: free, totalBytes: total)
    }
}
