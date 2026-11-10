import Foundation

/// Reads the `207 Multi-Status` answers of PROPFIND and converts paths to and from URL form.
public enum WebDAVParser {
    /// The body sent with PROPFIND: only the properties Navette shows.
    public static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)

    public static func parse(_ data: Data) throws -> [RemoteItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw RemoteError.protocolViolation(parser.parserError?.localizedDescription ?? "Invalid WebDAV answer")
        }
        return delegate.items
    }

    /// The path bytes of an `href`, which is either a path or a full URL, percent-encoded.
    public static func pathBytes(fromHref href: String) -> [UInt8] {
        var text = Substring(href.trimmingCharacters(in: .whitespacesAndNewlines))
        if let scheme = text.range(of: "://") {
            let afterHost = text[scheme.upperBound...]
            text = afterHost.firstIndex(of: "/").map { afterHost[$0...] } ?? "/"
        }
        if let query = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = text[..<query] }
        var bytes = [UInt8]()
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return bytes
    }

    /// Percent-encodes a path byte by byte, so any name survives the trip.
    public static func encode(_ path: RemotePath) -> String {
        var text = ""
        for byte in path.bytes {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "/"):
                text.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                text += String(format: "%%%02X", byte)
            }
        }
        return text
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    public static func date(_ text: String) -> Date? {
        dateFormatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items = [RemoteItem]()
        private var text = ""
        private var href: String?
        private var isCollection = false
        private var length: UInt64?
        private var modified: Date?
        // Properties of the propstat being read; kept only when its status is 200.
        private var pendingCollection = false
        private var pendingLength: UInt64?
        private var pendingModified: Date?
        private var pendingStatus: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "response":
                href = nil
                isCollection = false
                length = nil
                modified = nil
            case "propstat":
                pendingCollection = false
                pendingLength = nil
                pendingModified = nil
                pendingStatus = nil
            case "collection":
                pendingCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            switch elementName {
            case "href": if href == nil { href = text }
            case "getcontentlength": pendingLength = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "getlastmodified": pendingModified = WebDAVParser.date(text)
            case "status": pendingStatus = text
            case "propstat":
                if pendingStatus == nil || pendingStatus!.contains(" 200") {
                    isCollection = isCollection || pendingCollection
                    length = pendingLength ?? length
                    modified = pendingModified ?? modified
                }
            case "response":
                guard let href else { break }
                let path = RemotePath(bytes: WebDAVParser.pathBytes(fromHref: href))
                items.append(RemoteItem(path: path, kind: isCollection ? .directory : .file, size: isCollection ? nil : length, modified: modified))
            default: break
            }
            text = ""
        }
    }
}
