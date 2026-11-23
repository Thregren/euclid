import Foundation

/// The server accepts origin-form HTTP/1.x requests and bounded, complete headers only.
package struct LocalHTTPRequest: Sendable {
    package static let maximumHeaderBytes = 8192
    package let method: String
    package let path: String

    package init?(_ data: Data) {
        guard data.count <= Self.maximumHeaderBytes,
              let text = String(data: data, encoding: .utf8),
              text.contains("\r\n\r\n"), let end = text.range(of: "\r\n") else { return nil }
        let fields = text[..<end.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[0].isEmpty,
              fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0",
              fields[1].first == "/", !fields[1].contains("#"),
              fields[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        let tokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        guard fields[0].utf8.allSatisfy({ tokenCharacters.contains($0) }) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count <= 128, lines.suffix(2).allSatisfy(\.isEmpty) else { return nil }
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].utf8.allSatisfy({ tokenCharacters.contains($0) }) else { return nil }
            let value = line[line.index(after: colon)...]
            guard value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { return nil }
            let name = line[..<colon].lowercased()
            if name == "transfer-encoding" { return nil }
            if name == "content-length", value.trimmingCharacters(in: .whitespaces) != "0" { return nil }
        }
        method = String(fields[0])
        path = String(fields[1].prefix { $0 != "?" })
    }

    package static func tilePath(_ path: String) -> (tile: SlippyTile, ext: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty else { return nil }
        let name = parts[3].split(separator: ".", omittingEmptySubsequences: false)
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(text)
        }
        guard name.count == 2, let z = number(parts[1]), (0...30).contains(z),
              let x = number(parts[2]), let y = number(name[0]), x < 1 << z, y < 1 << z,
              ["png", "jpg", "jpeg", "webp"].contains(name[1].lowercased()) else { return nil }
        return (SlippyTile(zoom: z, x: x, y: y), name[1].lowercased())
    }
}
