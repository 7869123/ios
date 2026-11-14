import Foundation
import AIUtilityMedia
#if canImport(Compression)
import Compression
#endif

/// Ugoira frame delays (milliseconds) to GIF delays (centiseconds), compatibility first: each frame
/// ends at its true cumulative time rounded to 10 ms, so every frame is off by at most 5 ms and the
/// total stays exact. GIF viewers stretch delays under 2 cs, so such a frame gets 2 cs and the
/// excess is taken back from the following frames.
enum UgoiraTiming {
    static func centiseconds(_ milliseconds: [Int]) -> [Int] {
        var result: [Int] = []
        var elapsed = 0, emitted = 0
        for delay in milliseconds {
            elapsed += max(0, delay)
            let target = (elapsed + 5) / 10
            let value = max(2, target - emitted)
            result.append(value)
            emitted += value
        }
        return result
    }
}

/// Minimal read-only ZIP reader for Ugoira frame archives: stored entries everywhere, deflate where
/// the Compression framework exists. Encrypted, ZIP64 or multi-disk archives are `.unsupportedFormat`;
/// sizes and CRC-32 are checked, so a damaged archive is `.integrityMismatch`.
struct ZipArchive {
    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let dataOffset: Int
    }
    private let bytes: [UInt8]
    let entries: [String: Entry]

    init(_ data: Data, maxEntries: Int = 10_000) throws(MediaError) {
        let bytes = [UInt8](data)
        self.bytes = bytes
        func u16(_ at: Int) throws(MediaError) -> Int {
            guard at >= 0, at + 2 <= bytes.count else { throw .integrityMismatch }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws(MediaError) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { throw .integrityMismatch }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        guard bytes.count >= 22 else { throw .unsupportedFormat }
        var end = -1
        var position = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while position >= lowest {
            if bytes[position] == 0x50, bytes[position + 1] == 0x4b, bytes[position + 2] == 0x05, bytes[position + 3] == 0x06 {
                end = position; break
            }
            position -= 1
        }
        guard end >= 0 else { throw .unsupportedFormat }
        let disk = try u16(end + 4), cdDisk = try u16(end + 6)
        let count = try u16(end + 10), cdSize = try u32(end + 12), cdOffset = try u32(end + 16)
        guard disk == 0, cdDisk == 0, count != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else { throw .unsupportedFormat }
        guard count <= maxEntries else { throw .resourceLimitExceeded }
        guard cdOffset + cdSize <= end else { throw .integrityMismatch }
        var entries: [String: Entry] = [:]
        var p = cdOffset
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4b50 else { throw .integrityMismatch }
            let flags = try u16(p + 8), method = try u16(p + 10)
            let crc = try u32(p + 16), compressed = try u32(p + 20), size = try u32(p + 24)
            let nameLength = try u16(p + 28), extraLength = try u16(p + 30), commentLength = try u16(p + 32)
            let local = try u32(p + 42)
            guard flags & 0x1 == 0 else { throw .unsupportedFormat } // encrypted
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, local != 0xFFFF_FFFF else { throw .unsupportedFormat }
            guard p + 46 + nameLength <= bytes.count else { throw .integrityMismatch }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            guard try u32(local) == 0x0403_4b50 else { throw .integrityMismatch }
            let localName = try u16(local + 26), localExtra = try u16(local + 28)
            let dataOffset = local + 30 + localName + localExtra
            guard dataOffset + compressed <= cdOffset else { throw .integrityMismatch }
            if !name.hasSuffix("/") {
                guard entries[name] == nil else { throw .integrityMismatch }
                entries[name] = Entry(name: name, method: UInt16(method), crc: UInt32(crc), compressedSize: compressed,
                                      size: size, dataOffset: dataOffset)
            }
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func extract(_ name: String, maxBytes: Int) throws(MediaError) -> Data {
        guard let entry = entries[name] else { throw .parsingChanged }
        guard entry.size <= maxBytes else { throw .resourceLimitExceeded }
        let raw = bytes[entry.dataOffset..<(entry.dataOffset + entry.compressedSize)]
        let output: [UInt8]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw .integrityMismatch }
            output = Array(raw)
        case 8:
            output = try Self.inflate(Array(raw), size: entry.size)
        default:
            throw .unsupportedFormat
        }
        guard CRC32.checksum(output) == entry.crc else { throw .integrityMismatch }
        return Data(output)
    }

    private static func inflate(_ input: [UInt8], size: Int) throws(MediaError) -> [UInt8] {
        #if canImport(Compression)
        guard size > 0 else { return [] }
        guard !input.isEmpty else { throw .integrityMismatch }
        // One spare byte detects output longer than the declared size.
        var output = [UInt8](repeating: 0, count: size + 1)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw .integrityMismatch }
        output.removeLast()
        return output
        #else
        throw .unsupportedFormat
        #endif
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Turns a downloaded Ugoira archive into a GIF that keeps the original frame order and timeline
/// (see `UgoiraTiming`). Frames of a different size are scaled to the first frame's size. The result
/// is read back and checked (frame count and every delay) before it is written, once, atomically.
public struct UgoiraAssembler: MediaAssembler {
    public let limits: MediaProcessingLimits
    public init(limits: MediaProcessingLimits = MediaProcessingLimits(maxGIFFrames: 2_000, maxGIFDuration: 600)) {
        self.limits = limits
    }

    public func assemble(_ job: AssemblyJob) async throws(MediaError) -> AssemblyResult {
        guard case .ugoiraToGIF = job.assembly, job.inputs.count == 1, !job.ugoiraFrames.isEmpty else { throw .unsupportedFormat }
        guard job.ugoiraFrames.count <= limits.maxGIFFrames,
              Double(job.ugoiraFrames.reduce(0) { $0 + $1.delayMilliseconds }) / 1000 <= limits.maxGIFDuration
        else { throw .resourceLimitExceeded }
        #if canImport(ImageIO) && canImport(CoreGraphics)
        let values = try? job.inputs[0].resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw .outputMissing }
        guard Int64(size) <= limits.maxInputBytes else { throw .resourceLimitExceeded }
        let archiveData: Data
        do { archiveData = try Data(contentsOf: job.inputs[0]) } catch { throw .storageUnavailable }
        let archive = try ZipArchive(archiveData)
        let delays = UgoiraTiming.centiseconds(job.ugoiraFrames.map { $0.delayMilliseconds })
        let gif = try encode(job.ugoiraFrames, delays: delays, archive: archive)
        guard !Task.isCancelled else { throw .cancelled }
        guard let summary = GIFInspector.inspect(gif), summary.frameCount == delays.count,
              summary.delaysCentiseconds == delays else { throw .unsupportedFormat }
        guard Int64(gif.count) <= min(job.maxOutputBytes, limits.maxOutputBytes) else { throw .resourceLimitExceeded }
        let file = job.outputDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".gif")
        do { try gif.write(to: file, options: .atomic) }
        catch { throw (error as NSError).code == NSFileWriteOutOfSpaceError ? .storageFull : .storageUnavailable }
        return AssemblyResult(file: file, fileExtension: "gif")
        #else
        throw .unsupportedPlatform
        #endif
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private func encode(_ frames: [UgoiraFrame], delays: [Int], archive: ZipArchive) throws(MediaError) -> Data {
        let encoder = try GIFEncoder(frameCount: frames.count, loopCount: 0)
        var size: (width: Int, height: Int)?
        for (frame, delay) in zip(frames, delays) {
            guard !Task.isCancelled else { throw .cancelled }
            let bytes = try archive.extract(frame.file, maxBytes: Int(min(limits.maxInputBytes, Int64(Int.max))))
            let source = try ImageIOSupport.open(bytes, limits: limits)
            let image = try ImageIOSupport.orientedImage(source)
            if size == nil { size = (image.width, image.height) }
            try encoder.append(try fitted(image, to: size!), delayCentiseconds: delay)
        }
        return try encoder.finish()
    }
    #endif
}
