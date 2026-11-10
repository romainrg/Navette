import Foundation
import NavetteCore
import Observation

/// User settings. `defaults` is nil in demo mode, which keeps everything in memory.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults?

    var downloadFolder: URL { didSet { defaults?.set(downloadFolder.path, forKey: "downloadFolder") } }
    var conflictPolicy: ConflictPolicy { didSet { defaults?.set(conflictPolicy.rawValue, forKey: "conflictPolicy") } }
    var maxConcurrentTransfers: Int { didSet { defaults?.set(maxConcurrentTransfers, forKey: "maxConcurrentTransfers") } }
    /// Kilobytes per second; 0 means unlimited.
    var rateLimitKB: Int { didSet { defaults?.set(rateLimitKB, forKey: "rateLimitKB") } }
    var showHiddenFiles: Bool { didSet { defaults?.set(showHiddenFiles, forKey: "showHiddenFiles") } }

    init(defaults: UserDefaults?, downloadFolder: URL) {
        self.defaults = defaults
        self.downloadFolder = defaults?.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? downloadFolder
        conflictPolicy = defaults?.string(forKey: "conflictPolicy").flatMap(ConflictPolicy.init(rawValue:)) ?? .ask
        maxConcurrentTransfers = (defaults?.object(forKey: "maxConcurrentTransfers") as? Int).map { min(max($0, 1), 8) } ?? 2
        rateLimitKB = max(0, defaults?.integer(forKey: "rateLimitKB") ?? 0)
        showHiddenFiles = defaults?.bool(forKey: "showHiddenFiles") ?? false
    }
}
