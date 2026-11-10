// navette-askpass: the program `ssh` runs (through SSH_ASKPASS) when it needs a password, a passphrase,
// a one-time code or a host key confirmation. It holds no logic: it forwards the question to Navette over
// a private Unix socket and prints the answer. See AskpassServer in NavetteCore for the wire format.
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let socketPath = environment["NAVETTE_ASKPASS_SOCKET"],
      let token = environment["NAVETTE_ASKPASS_TOKEN"],
      CommandLine.arguments.count > 1 else { exit(2) }

let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard descriptor >= 0, pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(3) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(3) }

let hint = environment["SSH_ASKPASS_PROMPT"] ?? ""
let message = Array("\(token)\n\(hint)\n\(CommandLine.arguments[1])".utf8)
_ = message.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
shutdown(descriptor, SHUT_WR)

// For a notice ("touch your security key"), no reply comes: ssh ends this process when the notice is over.
var reply = [UInt8]()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let count = read(descriptor, &buffer, buffer.count)
    if count <= 0 { break }
    reply.append(contentsOf: buffer[0..<count])
}
guard reply.first == UInt8(ascii: "0") else { exit(1) }
FileHandle.standardOutput.write(Data(reply.dropFirst()) + Data("\n".utf8))
