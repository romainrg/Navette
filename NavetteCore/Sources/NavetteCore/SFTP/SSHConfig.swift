import Foundation

/// What `ssh -G <host>` reports: the values `ssh` will really use once `~/.ssh/config` is applied.
public struct ResolvedSSHConfig: Equatable, Sendable {
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String] = []
    public var proxyJump: String?
    public var proxyCommand: String?
    public var identityAgent: String?
    /// True when the user configured connection sharing themselves.
    public var usesControlMaster = false

    public init() {}

    public static func parse(_ output: String) -> ResolvedSSHConfig {
        var config = ResolvedSSHConfig()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space].lowercased()
            let value = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "hostname": config.hostName = value
            case "user": config.user = value
            case "port": config.port = Int(value)
            case "identityfile": config.identityFiles.append(value)
            case "proxyjump": config.proxyJump = value == "none" ? nil : value
            case "proxycommand": config.proxyCommand = value == "none" ? nil : value
            case "identityagent": config.identityAgent = value == "none" ? nil : value
            case "controlmaster": if value != "false" && value != "no" { config.usesControlMaster = true }
            case "controlpath": if value != "none" { config.usesControlMaster = true }
            default: break
            }
        }
        return config
    }

    /// Identity files that exist on disk, the only ones worth showing.
    public func existingIdentityFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        identityFiles.filter { path in
            let expanded = path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
            return FileManager.default.fileExists(atPath: expanded)
        }
    }
}

public enum SSHConfigResolver {
    /// Runs `ssh -G`. Returns `nil` when the host is not valid or `ssh` fails.
    public static func resolve(host: String, user: String? = nil, port: Int? = nil, extraOptions: [String] = []) async -> ResolvedSSHConfig? {
        guard let arguments = try? SSHCommand.resolveArguments(host: host, user: user, port: port, extraOptions: extraOptions),
              let output = try? await ProcessRunner.run(SSHCommand.executable, arguments, timeout: 5),
              output.status == 0 else { return nil }
        return ResolvedSSHConfig.parse(output.text)
    }
}
