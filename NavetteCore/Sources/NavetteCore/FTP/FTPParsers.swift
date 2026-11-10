import Foundation

/// One reply on the FTP control connection: a three-digit code and one or more lines of text.
public struct FTPReply: Equatable, Sendable {
    public var code: Int
    /// The lines without the code prefix. Multi-line replies keep their inner lines as sent.
    public var lines: [[UInt8]]

    public init(code: Int, lines: [[UInt8]]) {
        self.code = code
        self.lines = lines
    }

    public var text: String { lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") }
    public var isPreliminary: Bool { (100..<200).contains(code) }
    public var isCompletion: Bool { (200..<300).contains(code) }
    public var isIntermediate: Bool { (300..<400).contains(code) }
}

/// Splits the bytes of the control connection into replies.
public struct FTPReplyParser {
    private var buffer = [UInt8]()
    private var pendingCode: Int?
    private var pendingLines = [[UInt8]]()

    public init() {}

    public mutating func append(_ data: Data) throws -> [FTPReply] {
        buffer.append(contentsOf: data)
        guard buffer.count < 1 << 20 else { throw RemoteError.protocolViolation("FTP reply too long") }
        var replies = [FTPReply]()
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = Array(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            let code = line.count >= 3 ? Int(String(decoding: line.prefix(3), as: UTF8.self)) : nil
            let separator = line.count > 3 ? line[3] : UInt8(ascii: " ")
            if let pending = pendingCode {
                if code == pending, separator == UInt8(ascii: " ") {
                    pendingLines.append(Array(line.dropFirst(4)))
                    replies.append(FTPReply(code: pending, lines: pendingLines))
                    pendingCode = nil
                    pendingLines = []
                } else {
                    pendingLines.append(line)
                }
            } else if let code, (100..<600).contains(code) {
                if separator == UInt8(ascii: "-") {
                    pendingCode = code
                    pendingLines = [Array(line.dropFirst(4))]
                } else {
                    replies.append(FTPReply(code: code, lines: [Array(line.dropFirst(4))]))
                }
            } else if !line.isEmpty {
                throw RemoteError.protocolViolation("Unexpected FTP reply")
            }
        }
        return replies
    }
}

public enum FTPListParser {
    // MARK: - Replies

    /// `257 "/home/me" is the current directory`, with `""` standing for a quote inside the path.
    public static func parsePWD(_ line: [UInt8]) -> RemotePath? {
        guard let start = line.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        var path = [UInt8]()
        var index = start + 1
        while index < line.count {
            if line[index] == UInt8(ascii: "\"") {
                if index + 1 < line.count, line[index + 1] == UInt8(ascii: "\"") {
                    path.append(UInt8(ascii: "\""))
                    index += 2
                    continue
                }
                return RemotePath(bytes: path)
            }
            path.append(line[index])
            index += 1
        }
        return nil
    }

    /// `229 Entering Extended Passive Mode (|||30039|)`
    public static func parseEPSV(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: #/\((.)\1\1(\d+)\1\)/#) else { return nil }
        return Int(match.2).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// `227 Entering Passive Mode (192,168,1,2,117,48)`: only the port is used, the address is the server's own.
    public static func parsePASV(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: #/(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/#),
              let high = Int(match.5), let low = Int(match.6), high < 256, low < 256 else { return nil }
        return high * 256 + low
    }

    /// The feature names of a FEAT reply, uppercased ("MLST", "UTF8", "REST STREAM"...).
    public static func features(_ reply: FTPReply) -> Set<String> {
        Set(reply.lines.dropFirst().dropLast().map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased() }
            .flatMap { line -> [String] in [line, String(line.split(separator: " ").first ?? "")] })
    }

    // MARK: - MLSD and MLST

    public static func parseMLSD(_ data: Data, directory: RemotePath) -> [RemoteItem] {
        lines(data).compactMap { parseFacts($0, directory: directory) }
    }

    /// One line of facts: `type=file;size=1234;modify=20261110100000;UNIX.mode=0644; name`.
    public static func parseFacts(_ line: [UInt8], directory: RemotePath) -> RemoteItem? {
        guard let space = line.firstIndex(of: UInt8(ascii: " ")) else { return nil }
        let name = Array(line[(space + 1)...])
        guard isUsableName(name) else { return nil }
        var facts: [String: String] = [:]
        for fact in String(decoding: line[..<space], as: UTF8.self).split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<equals].lowercased()] = String(fact[fact.index(after: equals)...])
        }
        let type = facts["type"]?.lowercased() ?? "file"
        let kind: RemoteItem.Kind
        var target: String?
        switch type {
        case "cdir", "pdir": return nil
        case "dir": kind = .directory
        case "file": kind = .file
        default:
            if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
                kind = .symlink
                target = type.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
            } else {
                kind = .other
            }
        }
        // A name with a slash is an absolute path (MLST): keep only its last component.
        let path = name.contains(UInt8(ascii: "/")) ? RemotePath(bytes: name) : directory.appending(name)
        return RemoteItem(
            path: path, kind: kind, size: kind == .directory ? nil : facts["size"].flatMap { UInt64($0) },
            modified: facts["modify"].flatMap(timestamp),
            permissions: facts["unix.mode"].flatMap { UInt16($0, radix: 8) }.map { $0 & 0o7777 },
            owner: facts["unix.ownername"] ?? facts["unix.owner"] ?? facts["unix.uid"],
            group: facts["unix.groupname"] ?? facts["unix.group"] ?? facts["unix.gid"], linkTarget: target)
    }

    /// `YYYYMMDDHHMMSS[.sss]`, in UTC.
    public static func timestamp(_ text: String) -> Date? {
        let digits = text.prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func part(_ start: Int, _ length: Int) -> Int {
            Int(digits[digits.index(digits.startIndex, offsetBy: start)..<digits.index(digits.startIndex, offsetBy: start + length)]) ?? 0
        }
        var components = DateComponents()
        components.year = part(0, 4)
        components.month = part(4, 2)
        components.day = part(6, 2)
        components.hour = part(8, 2)
        components.minute = part(10, 2)
        components.second = part(12, 2)
        return utc.date(from: components)
    }

    // MARK: - LIST

    /// Parses a `LIST` answer in Unix (`ls -l`) or DOS/IIS format. `now` decides the year of dates given without one.
    public static func parseLIST(_ data: Data, directory: RemotePath, now: Date = Date()) -> [RemoteItem] {
        lines(data).compactMap { parseUnixLine($0, directory: directory, now: now) ?? parseDOSLine($0, directory: directory) }
    }

    static func parseUnixLine(_ line: [UInt8], directory: RemotePath, now: Date) -> RemoteItem? {
        guard line.count > 10, let typeCharacter = line.first, "-dlbcps".utf8.contains(typeCharacter) else { return nil }
        // Fields are separated by runs of spaces. The name comes after the date and may itself contain spaces,
        // so the first fields are located by position and the rest of the line is kept as it is.
        var tokens = [(text: String, end: Int)]()
        var index = 0
        while index < line.count, tokens.count < 9 {
            while index < line.count, line[index] == UInt8(ascii: " ") { index += 1 }
            let start = index
            while index < line.count, line[index] != UInt8(ascii: " ") { index += 1 }
            if index > start { tokens.append((String(decoding: line[start..<index], as: UTF8.self), index)) }
        }
        // permissions links owner [group] size month day time-or-year name
        guard let monthIndex = (3...5).first(where: { $0 + 2 < tokens.count && months[tokens[$0].text.lowercased()] != nil && Int(tokens[$0 + 1].text) != nil }),
              let monthNumber = months[tokens[monthIndex].text.lowercased()], let day = Int(tokens[monthIndex + 1].text) else { return nil }
        let timeOrYear = tokens[monthIndex + 2].text
        let nameStart = tokens[monthIndex + 2].end + 1
        guard nameStart < line.count else { return nil }
        var name = Array(line[nameStart...])
        let size = UInt64(tokens[monthIndex - 1].text)
        let owner = monthIndex >= 4 ? tokens[2].text : nil
        let group = monthIndex == 5 ? tokens[3].text : nil

        let kind: RemoteItem.Kind
        var target: String?
        switch typeCharacter {
        case UInt8(ascii: "d"): kind = .directory
        case UInt8(ascii: "-"): kind = .file
        case UInt8(ascii: "l"):
            kind = .symlink
            if let range = name.firstRange(of: Array(" -> ".utf8)) {
                target = String(decoding: name[range.upperBound...], as: UTF8.self)
                name = Array(name[..<range.lowerBound])
            }
        default: kind = .other
        }
        guard isUsableName(name) else { return nil }

        var components = DateComponents()
        components.month = monthNumber
        components.day = day
        var modified: Date?
        if let colon = timeOrYear.firstIndex(of: ":") {
            components.hour = Int(timeOrYear[..<colon])
            components.minute = Int(timeOrYear[timeOrYear.index(after: colon)...])
            // A date without a year is within the last twelve months.
            let year = utc.component(.year, from: now)
            components.year = year
            if let date = utc.date(from: components), date > now.addingTimeInterval(86_400) { components.year = year - 1 }
            modified = utc.date(from: components)
        } else if let year = Int(timeOrYear) {
            components.year = year
            modified = utc.date(from: components)
        }
        return RemoteItem(
            path: directory.appending(name), kind: kind, size: kind == .directory ? nil : size, modified: modified,
            permissions: permissions(fromSymbolic: Array(line[1..<10])), owner: owner, group: group, linkTarget: target)
    }

    /// `11-10-26  10:00AM       <DIR>          name` or `11-10-2026  10:00AM            1234 name`.
    static func parseDOSLine(_ line: [UInt8], directory: RemotePath) -> RemoteItem? {
        let string = String(decoding: line, as: UTF8.self)
        guard let match = string.firstMatch(of: #/^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*([AP]M)?\s+(<DIR>|\d+)\s+(.+)$/#) else { return nil }
        let name = Array(String(match.8).utf8)
        guard isUsableName(name) else { return nil }
        var components = DateComponents()
        components.month = Int(match.1)
        components.day = Int(match.2)
        let year = Int(match.3) ?? 0
        components.year = year < 100 ? (year < 70 ? 2000 + year : 1900 + year) : year
        var hour = Int(match.4) ?? 0
        if let period = match.6 {
            if period == "PM", hour < 12 { hour += 12 }
            if period == "AM", hour == 12 { hour = 0 }
        }
        components.hour = hour
        components.minute = Int(match.5)
        let isDirectory = match.7 == "<DIR>"
        return RemoteItem(
            path: directory.appending(name), kind: isDirectory ? .directory : .file,
            size: isDirectory ? nil : UInt64(match.7), modified: utc.date(from: components))
    }

    /// `rwxr-xr-x` (with `s`, `S`, `t`, `T`) to permission bits.
    static func permissions(fromSymbolic symbols: [UInt8]) -> UInt16? {
        guard symbols.count == 9 else { return nil }
        var bits: UInt16 = 0
        for (index, symbol) in symbols.enumerated() {
            let bit: UInt16 = 1 << UInt16(8 - index)
            switch symbol {
            case UInt8(ascii: "r"), UInt8(ascii: "w"), UInt8(ascii: "x"): bits |= bit
            case UInt8(ascii: "s"): bits |= bit | (index == 2 ? 0o4000 : 0o2000)
            case UInt8(ascii: "S"): bits |= index == 2 ? 0o4000 : 0o2000
            case UInt8(ascii: "t"): bits |= bit | 0o1000
            case UInt8(ascii: "T"): bits |= 0o1000
            case UInt8(ascii: "-"): break
            default: return nil
            }
        }
        return bits
    }

    // MARK: - Helpers

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func lines(_ data: Data) -> [[UInt8]] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { line in
            var bytes = Array(line)
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            return bytes
        }
    }

    /// Rejects `.`, `..` and names no file system can hold, so a hostile server cannot aim elsewhere.
    private static func isUsableName(_ name: [UInt8]) -> Bool {
        if name.isEmpty || name == [UInt8(ascii: ".")] || name == [UInt8(ascii: "."), UInt8(ascii: ".")] || name.contains(0) { return false }
        // A slash is only accepted in the absolute path MLST returns.
        return !name.contains(UInt8(ascii: "/")) || name.first == UInt8(ascii: "/")
    }
}
