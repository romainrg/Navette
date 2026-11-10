import CryptoKit
import Foundation
import Security

public struct WebDAVConnection: Sendable {
    /// Scheme, host and port: `https://cloud.example.org` or `http://nas.local:8080`.
    public var baseURL: URL
    public var user: String?
    public var password: String?
    /// SHA-256 of a certificate the user chose to trust although the system does not.
    public var trustedCertificateSHA256: String?

    public init(baseURL: URL, user: String? = nil, password: String? = nil, trustedCertificateSHA256: String? = nil) {
        self.baseURL = baseURL
        self.user = user
        self.password = password
        self.trustedCertificateSHA256 = trustedCertificateSHA256
    }
}

/// Describes a TLS certificate for the trust sheet, and tells whether the system trusts it.
public enum CertificateInspector {
    public static func sha256(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// `nil` when the system trusts the chain; otherwise what to show the user.
    public static func problem(with trust: SecTrust) -> CertificateSummary? {
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return CertificateSummary(subject: "", issuer: "", sha256: "", reason: "No certificate")
        }
        let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: [CFString: Any]]
        func date(_ key: CFString) -> Date? {
            (values?[key]?[kSecPropertyKeyValue] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        let issuerParts = values?[kSecOIDX509V1IssuerName]?[kSecPropertyKeyValue] as? [[CFString: Any]] ?? []
        let issuer = issuerParts.compactMap { $0[kSecPropertyKeyValue] as? String }.last ?? ""
        return CertificateSummary(
            subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "", issuer: issuer,
            notBefore: date(kSecOIDX509V1ValidityNotBefore), notAfter: date(kSecOIDX509V1ValidityNotAfter),
            sha256: sha256(of: leaf),
            reason: (error.map { CFErrorCopyDescription($0) as String }) ?? "Not trusted")
    }
}

/// WebDAV over URLSession: PROPFIND, MKCOL, MOVE, DELETE, ranged GET and streamed PUT.
public final class WebDAVFileSystem: NSObject, RemoteFileSystem, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: WebDAVConnection
    private let lock = NSLock()
    private var session: URLSession!
    private var downloads: [Int: Download] = [:]
    private var uploads: [Int: Upload] = [:]
    private var certificateProblem: CertificateSummary?

    public let capabilities = Capabilities(atomicReplace: true, resumeDownload: true)

    public init(connection: WebDAVConnection) {
        self.connection = connection
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func disconnect() async {
        session.invalidateAndCancel()
    }

    // MARK: - Requests

    private func url(_ path: RemotePath, directory: Bool = false) -> URL {
        var text = connection.baseURL.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        text += WebDAVParser.encode(path)
        if directory, !text.hasSuffix("/") { text += "/" }
        return URL(string: text) ?? connection.baseURL
    }

    private func request(_ method: String, _ path: RemotePath, directory: Bool = false, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url(path, directory: directory))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func send(_ request: URLRequest, path: RemotePath, accept: Set<Int>) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RemoteError.protocolViolation("Not an HTTP answer") }
            guard accept.contains(http.statusCode) else { throw Self.error(status: http.statusCode, method: request.httpMethod ?? "", path: path) }
            return (data, http)
        } catch let error as URLError {
            throw map(error)
        }
    }

    private func map(_ error: URLError) -> RemoteError {
        if let problem = lock.withLock({ certificateProblem }) { return .untrustedCertificate(problem) }
        switch error.code {
        case .cancelled: return .cancelled
        case .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed, .notConnectedToInternet: return .unreachable(error.localizedDescription)
        case .networkConnectionLost: return .connectionLost(error.localizedDescription)
        case .userAuthenticationRequired, .userCancelledAuthentication: return .authenticationFailed(error.localizedDescription)
        default: return .server(error.localizedDescription)
        }
    }

    static func error(status: Int, method: String, path: RemotePath) -> RemoteError {
        switch status {
        case 401: .authenticationFailed("HTTP 401")
        case 403: .permissionDenied(path.display)
        case 404, 410: .notFound(path.display)
        case 405 where method == "MKCOL": .alreadyExists(path.display)
        case 409: .notFound(path.parent.display)
        case 412: .alreadyExists(path.display)
        case 423: .server("Locked: \(path.display)")
        case 507: .server("The server is out of space.")
        default: .server("HTTP \(status): \(path.display)")
        }
    }

    // MARK: - Metadata

    public func home() async throws -> RemotePath { .root }

    private func propfind(_ path: RemotePath, depth: String, directory: Bool) async throws -> [RemoteItem] {
        let request = request("PROPFIND", path, directory: directory, headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"], body: WebDAVParser.propfindBody)
        let (data, _) = try await send(request, path: path, accept: [207])
        return try WebDAVParser.parse(data)
    }

    public func list(_ path: RemotePath) async throws -> [RemoteItem] {
        let items = try await propfind(path, depth: "1", directory: true)
        if items.contains(where: { $0.path == path && $0.kind == .file }) {
            throw RemoteError.server("Not a directory: \(path.display)")
        }
        // Only direct children with names a file system can hold: a hostile server cannot aim elsewhere.
        return items.filter { $0.path != path && $0.path.parent == path && TransferPlanner.isSafeName($0.name) }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        guard let item = try await propfind(path, depth: "0", directory: false).first else { throw RemoteError.notFound(path.display) }
        return RemoteItem(path: path, kind: item.kind, size: item.size, modified: item.modified)
    }

    // MARK: - Changes

    public func makeDirectory(_ path: RemotePath) async throws {
        _ = try await send(request("MKCOL", path, directory: true), path: path, accept: [200, 201, 204])
    }

    public func rename(_ source: RemotePath, to destination: RemotePath, overwrite: Bool) async throws {
        let headers = ["Destination": url(destination).absoluteString, "Overwrite": overwrite ? "T" : "F"]
        do {
            _ = try await send(request("MOVE", source, headers: headers), path: source, accept: [200, 201, 204])
        } catch RemoteError.alreadyExists {
            throw RemoteError.alreadyExists(destination.display)
        }
    }

    public func removeFile(_ path: RemotePath) async throws {
        _ = try await send(request("DELETE", path), path: path, accept: [200, 202, 204])
    }

    /// WebDAV deletes a collection with everything inside. Navette only deletes what the user saw, so a
    /// folder that is not empty is refused.
    public func removeDirectory(_ path: RemotePath) async throws {
        guard try await list(path).isEmpty else { throw RemoteError.directoryNotEmpty(path.display) }
        _ = try await send(request("DELETE", path, directory: true), path: path, accept: [200, 202, 204])
    }

    public func setPermissions(_ permissions: UInt16, of path: RemotePath) async throws {
        throw RemoteError.unsupported("chmod")
    }

    // MARK: - Download

    public func read(_ path: RemotePath, offset: UInt64) async throws -> any RemoteReader {
        var request = request("GET", path)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        let download = Download(task: task, path: path, offset: offset, owner: self)
        lock.withLock { downloads[task.taskIdentifier] = download }
        task.resume()
        return download
    }

    /// A GET in progress. URLSession pushes data; the task is suspended while the reader is behind, so memory stays bounded.
    private final class Download: RemoteReader, @unchecked Sendable {
        private static let highWater = 8 << 20
        private static let lowWater = 2 << 20

        let task: URLSessionDataTask
        let path: RemotePath
        private weak var owner: WebDAVFileSystem?
        private let lock = NSLock()
        private var chunks: [Data] = []
        private var buffered = 0
        private var toSkip: UInt64
        private var suspended = false
        private var finished = false
        private var failure: RemoteError?
        private var waiter: CheckedContinuation<Void, Never>?

        init(task: URLSessionDataTask, path: RemotePath, offset: UInt64, owner: WebDAVFileSystem) {
            self.task = task
            self.path = path
            self.owner = owner
            // Decided when the answer arrives: a server that ignores Range sends everything from the start.
            toSkip = offset
        }

        func received(response: HTTPURLResponse) -> Bool {
            lock.withLock {
                switch response.statusCode {
                case 206: toSkip = 0
                case 200: break
                case 416:
                    // The offset is the end of the file: nothing left to read.
                    finished = true
                    return false
                default:
                    failure = WebDAVFileSystem.error(status: response.statusCode, method: "GET", path: path)
                    return false
                }
                return true
            }
        }

        func received(_ data: Data) {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                var data = data
                if toSkip > 0 {
                    let drop = Int(min(UInt64(data.count), toSkip))
                    toSkip -= UInt64(drop)
                    data = data.dropFirst(drop)
                }
                if !data.isEmpty {
                    chunks.append(Data(data))
                    buffered += data.count
                }
                if buffered > Self.highWater, !suspended {
                    suspended = true
                    task.suspend()
                }
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func completed(_ error: RemoteError?) {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                finished = true
                if failure == nil { failure = error }
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func next() async throws -> Data? {
            while true {
                let result: Result<Data?, RemoteError>? = lock.withLock {
                    if !chunks.isEmpty {
                        let chunk = chunks.removeFirst()
                        buffered -= chunk.count
                        if suspended, buffered < Self.lowWater {
                            suspended = false
                            task.resume()
                        }
                        return .success(chunk)
                    }
                    if let failure { return .failure(failure) }
                    if finished { return .success(nil) }
                    return nil
                }
                if let result { return try result.get() }
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock { () -> Bool in
                        if !chunks.isEmpty || finished || failure != nil { return true }
                        waiter = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }

        func close() async {
            task.cancel()
            owner?.forget(task)
        }
    }

    private func forget(_ task: URLSessionTask) {
        lock.withLock {
            downloads[task.taskIdentifier] = nil
            uploads[task.taskIdentifier] = nil
        }
    }

    // MARK: - Upload

    public func write(_ path: RemotePath, offset: UInt64?) async throws -> any RemoteWriter {
        try await write(path, offset: offset, size: nil)
    }

    public func write(_ path: RemotePath, offset: UInt64?, size: UInt64?) async throws -> any RemoteWriter {
        guard offset == nil || offset == 0 else { throw RemoteError.unsupported("Resuming an upload") }
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1 << 20, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw RemoteError.server("Cannot create the upload stream") }
        var request = request("PUT", path)
        // With a known length the body is not sent chunked, which some servers refuse.
        if let size { request.setValue(String(size), forHTTPHeaderField: "Content-Length") }
        let task = session.uploadTask(withStreamedRequest: request)
        let upload = Upload(task: task, input: input, output: output, path: path, owner: self)
        lock.withLock { uploads[task.taskIdentifier] = upload }
        output.open()
        task.resume()
        return upload
    }

    /// A PUT in progress: the writer feeds a bound stream pair that URLSession reads from.
    private final class Upload: RemoteWriter, @unchecked Sendable {
        let task: URLSessionUploadTask
        let input: InputStream
        private let output: OutputStream
        private let path: RemotePath
        private weak var owner: WebDAVFileSystem?
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "io.github.romainrg.Navette.webdav.upload")
        private var result: Result<Void, RemoteError>?
        private var waiter: CheckedContinuation<Void, Never>?

        init(task: URLSessionUploadTask, input: InputStream, output: OutputStream, path: RemotePath, owner: WebDAVFileSystem) {
            self.task = task
            self.input = input
            self.output = output
            self.path = path
            self.owner = owner
        }

        func completed(_ result: Result<Void, RemoteError>) {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                if self.result == nil { self.result = result }
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    var offset = 0
                    while offset < data.count {
                        if case .failure(let error)? = lock.withLock({ result }) {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard output.hasSpaceAvailable else {
                            usleep(2_000)
                            continue
                        }
                        let written = data.withUnsafeBytes { raw in
                            output.write(raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), maxLength: data.count - offset)
                        }
                        if written <= 0 {
                            continuation.resume(throwing: RemoteError.connectionLost(output.streamError?.localizedDescription ?? "Upload interrupted"))
                            return
                        }
                        offset += written
                    }
                    continuation.resume()
                }
            }
        }

        func close() async throws {
            queue.sync { output.close() }
            while lock.withLock({ result }) == nil {
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock { () -> Bool in
                        if result != nil { return true }
                        waiter = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
            owner?.forget(task)
            try lock.withLock { result }?.get()
        }

        func abort() async {
            task.cancel()
            queue.async { [self] in output.close() }
            owner?.forget(task)
        }
    }

    // MARK: - URLSession delegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let download = lock.withLock({ downloads[dataTask.taskIdentifier] }), let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        completionHandler(download.received(response: http) ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { downloads[dataTask.taskIdentifier] }?.received(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(lock.withLock { uploads[task.taskIdentifier] }?.input)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (download, upload) = lock.withLock { (downloads[task.taskIdentifier], uploads[task.taskIdentifier]) }
        let mapped = (error as? URLError).map(map)
        if let download {
            download.completed(mapped == .cancelled ? nil : mapped)
        }
        if let upload {
            if let mapped {
                upload.completed(.failure(mapped))
            } else if let status = (task.response as? HTTPURLResponse)?.statusCode, ![200, 201, 204].contains(status) {
                upload.completed(.failure(Self.error(status: status, method: "PUT", path: RemotePath(task.originalRequest?.url?.path ?? "/"))))
            } else {
                upload.completed(.success(()))
            }
        }
    }

    /// A redirect keeps the method and the headers (servers redirect folder URLs to their form with a slash),
    /// but only towards the same server.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let target = request.url, target.host == original.url?.host, target.port == original.url?.port else {
            completionHandler(nil)
            return
        }
        var redirected = original
        redirected.url = target
        completionHandler(redirected)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let problem = CertificateInspector.problem(with: trust) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // Never bypassed silently: accepted only when the user trusted exactly this certificate.
            if let trusted = connection.trustedCertificateSHA256, trusted.lowercased() == problem.sha256 {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                lock.withLock { certificateProblem = problem }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            if challenge.previousFailureCount == 0, let user = connection.user, let password = connection.password {
                completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
