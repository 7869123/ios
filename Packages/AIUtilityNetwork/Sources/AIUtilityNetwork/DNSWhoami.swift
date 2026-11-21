import Foundation
#if canImport(dnssd)
import dnssd
#endif

/// Which DNS resolver answers this device's lookups. Akamai's diagnostic names answer a TXT query with the
/// address of the resolver that asked them (and the client subnet it forwarded, if any). Through the system
/// resolver this shows where DNS really goes, e.g. to the ISP while browsing goes through a VPN (a DNS leak).
public enum DNSWhoami {
    public static let names = ["whoami.ds.akahelp.net", "whoami.ipv4.akahelp.net", "whoami.ipv6.akahelp.net"]

    public struct Answer: Sendable, Equatable {
        /// Resolver address that contacted the authoritative server.
        public let resolver: String
        /// EDNS client subnet the resolver forwarded, if any (for example "198.51.100.0/24").
        public let clientSubnet: String?
    }

    /// TXT RDATA is a sequence of <length><bytes> character-strings.
    public static func characterStrings(_ rdata: [UInt8]) -> [String]? {
        var strings: [String] = [], offset = 0
        while offset < rdata.count {
            let length = Int(rdata[offset]); offset += 1
            guard offset + length <= rdata.count else { return nil }
            strings.append(String(decoding: rdata[offset..<offset + length], as: UTF8.self))
            offset += length
        }
        return strings
    }

    /// Records arrive as key/value pairs ("ns" <address>, "ecs" <subnet>, ...); several TXT records may come back.
    public static func answer(fromRecords records: [[String]]) -> Answer? {
        var resolver: String?, subnet: String?
        for strings in records {
            var i = 0
            while i + 1 < strings.count {
                let key = strings[i].lowercased(), value = strings[i + 1].trimmingCharacters(in: .whitespaces)
                if key == "ns", IPAddressText.family(value) != nil { resolver = value }
                if key == "ecs", value.count <= 64, value.allSatisfy({ $0.isHexDigit || ".:/".contains($0) }) { subnet = value }
                i += 2
            }
        }
        return resolver.map { Answer(resolver: $0, clientSubnet: subnet) }
    }

    #if canImport(dnssd)
    /// TXT lookup through the system resolver (the same path apps use), all answers within `timeout`.
    public static func query(_ name: String, timeout: TimeInterval = 5) async throws(NetworkToolError) -> Answer? {
        let handle = DNSQueryHandle()
        let once = Once<[[String]]>()
        let records: [[String]] = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.install(continuation)
                let queue = DispatchQueue(label: "aiutility.dns")
                guard handle.start(name, queue: queue) else { once.finish([]); return }
                queue.asyncAfter(deadline: .now() + timeout) {
                    handle.stop()
                    once.finish(handle.records)
                }
            }
        } onCancel: { once.finish([]) }
        if Task.isCancelled { throw .cancelled }
        return answer(fromRecords: records)
    }
    #endif
}

#if canImport(dnssd)
/// Owns the DNS-SD query and the records its C callback collects; only touched under its lock.
private final class DNSQueryHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var ref: DNSServiceRef?
    private var collected: [[String]] = []
    private var stopped = false

    func start(_ name: String, queue: DispatchQueue) -> Bool {
        var newRef: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = DNSServiceQueryRecord(&newRef, 0, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
            { _, _, _, error, _, _, _, length, rdata, _, context in
                guard let context, error == DNSServiceErrorType(kDNSServiceErr_NoError), let rdata else { return }
                let bytes = [UInt8](UnsafeRawBufferPointer(start: rdata, count: Int(length)))
                Unmanaged<DNSQueryHandle>.fromOpaque(context).takeUnretainedValue().add(bytes)
            }, context)
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let newRef else { return false }
        lock.withLock { ref = newRef }
        DNSServiceSetDispatchQueue(newRef, queue)
        return true
    }
    /// Called on the query's own queue, so no callback runs concurrently with the deallocation.
    func stop() {
        let current: DNSServiceRef? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true; let r = ref; ref = nil; return r
        }
        if let current { DNSServiceRefDeallocate(current) }
    }
    fileprivate func add(_ rdata: [UInt8]) {
        guard let strings = DNSWhoami.characterStrings(rdata) else { return }
        lock.withLock { if !stopped { collected.append(strings) } }
    }
    var records: [[String]] { lock.withLock { collected } }
}
#endif
