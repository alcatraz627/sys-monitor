import Foundation
import Darwin

/// System-wide network throughput sampler.
///
/// Reads `sysctl(NET_RT_IFLIST2)`, walks the returned routing-message blob,
/// and sums `ifi_ibytes` / `ifi_obytes` across non-loopback interfaces.
/// Uses the standard two-call sysctl pattern: ask once with a NULL buffer
/// to learn the needed size, then allocate and fetch.
public struct NetworkSampler: Sampler {
    public init() {}

    public func read() throws -> NetCounters {
        // Family 0 = all families; we only care about the interface-info
        // records (RTM_IFINFO2), which appear once per interface regardless.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        if sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) != 0 {
            throw SamplerError.sysctl(errno: errno, op: "sysctl size NET_RT_IFLIST2")
        }
        var buffer = [UInt8](repeating: 0, count: len)
        if sysctl(&mib, u_int(mib.count), &buffer, &len, nil, 0) != 0 {
            throw SamplerError.sysctl(errno: errno, op: "sysctl fetch NET_RT_IFLIST2")
        }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var ifaces: Set<String> = []
        var perInterface: [String: NetIfaceBytes] = [:]

        buffer.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < len {
                let hdrPtr = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self)
                let msglen = Int(hdrPtr.pointee.ifm_msglen)
                if msglen == 0 { break }
                // Only RTM_IFINFO2 records carry if_msghdr2 / if_data64. The
                // blob also contains address records (RTM_NEWADDR etc.) for
                // each interface — we skip those.
                if Int32(hdrPtr.pointee.ifm_type) == RTM_IFINFO2 {
                    let if2 = base.advanced(by: offset)
                        .assumingMemoryBound(to: if_msghdr2.self).pointee
                    // IFT_LOOP = 0x18 — loopback packets aren't real
                    // throughput and would dwarf the small numbers we care
                    // about during idle.
                    if if2.ifm_data.ifi_type != UInt8(IFT_LOOP) {
                        inBytes  &+= if2.ifm_data.ifi_ibytes
                        outBytes &+= if2.ifm_data.ifi_obytes
                        ifaces.insert("if\(if2.ifm_index)")
                        // Resolve the index to a name (en0, utun3, …) for the
                        // per-interface breakdown. A failed lookup just omits
                        // that interface from the split, not the aggregate.
                        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(if2.ifm_index), &nameBuf) != nil {
                            perInterface[String(cString: nameBuf)] = NetIfaceBytes(
                                inBytes: if2.ifm_data.ifi_ibytes,
                                outBytes: if2.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += msglen
            }
        }

        return NetCounters(inBytes: inBytes, outBytes: outBytes, ifaceSet: ifaces,
                           perInterface: perInterface)
    }
}
