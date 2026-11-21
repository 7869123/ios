import Foundation

/// Hand-written HTTP/1.1 over a raw TCP connection, for the China Academy of ICT test nodes: they speak plain
/// HTTP on an IP address and port, which URLSession (App Transport Security) would refuse, and the measuring
/// code needs exact control of headers and byte counts.
public enum HTTPWire {
    public struct Response: Sendable, Equatable {
        public let status: Int
        /// Header names in lower case.
        public let headers: [String: String]
        public let body: Data
        public init(status: Int, headers: [String: String] = [:], body: Data) {
            self.status = status; self.headers = headers; self.body = body
        }
    }

    /// Request bytes: request line, headers in the given order, blank line, then the body (if any).
    public static func request(_ method: String, _ target: String, headers: [(String, String)], body: Data = Data()) -> Data {
        var text = method + " " + target + " HTTP/1.1\r\n"
        for (name, value) in headers { text += name + ": " + value + "\r\n" }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    /// Offset just past the blank line that ends the header block, if it has arrived.
    public static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    /// Status code from "HTTP/1.1 200 OK".
    public static func status(ofHead head: [UInt8]) -> Int? {
        let line = String(decoding: head.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self)
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]), (100...599).contains(code) else { return nil }
        return code
    }

    /// A complete response read until the server closed the connection (`Connection: close`).
    public static func parse(_ data: Data) -> Response? {
        let bytes = [UInt8](data)
        guard let end = headerEnd(bytes), let code = status(ofHead: Array(bytes[..<end])) else { return nil }
        var headers: [String: String] = [:]
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Array(bytes[end...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(body) else { return nil }
            body = decoded
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard length >= 0, body.count >= length else { return nil }
            body = Array(body.prefix(length))
        }
        return Response(status: code, headers: headers, body: Data(body))
    }

    /// Chunked transfer coding: hex size line, data, CRLF, ... ending with a zero-size chunk.
    static func dechunk(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = [], index = 0
        while true {
            var lineEnd = index
            while lineEnd + 1 < bytes.count, !(bytes[lineEnd] == 13 && bytes[lineEnd + 1] == 10) { lineEnd += 1 }
            guard lineEnd + 1 < bytes.count else { return nil }
            let sizeText = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return nil }
            index = lineEnd + 2
            if size == 0 { return out }
            guard index + size <= bytes.count else { return nil }
            out += bytes[index..<index + size]
            index += size + 2
        }
    }
}
