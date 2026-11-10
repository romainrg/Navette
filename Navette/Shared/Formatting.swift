import AppKit
import NavetteCore
import SwiftUI
import UniformTypeIdentifiers

enum Format {
    static func bytes(_ count: UInt64) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .file))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        String(localized: "\(bytes(UInt64(max(0, bytesPerSecond))))/s")
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Compact form for table columns.
    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }

    static func remaining(_ seconds: Double) -> String {
        Duration.seconds(max(1, seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func kind(of item: RemoteItem) -> String {
        switch item.kind {
        case .directory: return String(localized: "Folder")
        case .symlink: return String(localized: "Symbolic link")
        case .other: return String(localized: "Special file")
        case .file:
            let ext = (item.name as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
                return description
            }
            return String(localized: "Document")
        }
    }

    static func count(files: Int, folders: Int) -> String {
        let fileText = String(localized: "\(files) files")
        let folderText = String(localized: "\(folders) folders")
        switch (files, folders) {
        case (_, 0): return fileText
        case (0, _): return folderText
        default: return "\(fileText), \(folderText)"
        }
    }
}

/// The file list's icons: the theme's gradient tiles, rendered once per kind of file.
@MainActor
enum FileIcons {
    static let size: CGFloat = 18
    private static var cache: [FileKind: NSImage] = [:]

    static func icon(for item: RemoteItem) -> NSImage {
        let kind = FileKind(item)
        if let cached = cache[kind] { return cached }
        let renderer = ImageRenderer(content: GradientTile(tint: kind.tint, symbol: kind.symbol, size: size))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: size, height: size)
        cache[kind] = image
        return image
    }
}

extension RemoteError {
    /// What the user reads when something fails.
    var message: String {
        switch self {
        case .notFound(let path): String(localized: "“\(path)” does not exist.")
        case .permissionDenied(let path): String(localized: "You do not have permission to access “\(path)”.")
        case .alreadyExists(let path): String(localized: "“\(path)” already exists.")
        case .directoryNotEmpty(let path): String(localized: "“\(path)” is not empty: new items appeared in it and were left in place.")
        case .unsupported(let what): String(localized: "The server does not support this: \(what)")
        case .connectionLost(let detail): String(localized: "The connection was lost. \(detail)")
        case .authenticationFailed(let detail): String(localized: "The server refused the login. \(detail)")
        case .hostKeyChanged(let change): String(localized: "The identity of “\(change.host)” has changed.")
        case .untrustedCertificate(let certificate): String(localized: "The certificate of the server is not trusted: \(certificate.reason)")
        case .unreachable(let detail): String(localized: "The server cannot be reached. \(detail)")
        case .cancelled: String(localized: "Cancelled.")
        case .server(let detail): detail
        case .protocolViolation(let detail): String(localized: "The server sent an invalid reply. \(detail)")
        }
    }
}

extension TransferState {
    var label: String {
        switch self {
        case .queued: String(localized: "Waiting")
        case .running: String(localized: "Transferring")
        case .paused: String(localized: "Paused")
        case .finished: String(localized: "Done")
        case .skipped: String(localized: "Skipped")
        case .failed(let error): String(localized: "Interrupted: \(error.message)")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

extension ConflictPolicy {
    var label: String {
        switch self {
        case .ask: String(localized: "Ask")
        case .overwrite: String(localized: "Overwrite")
        case .resume: String(localized: "Resume")
        case .rename: String(localized: "Rename")
        case .skip: String(localized: "Skip")
        }
    }
}
