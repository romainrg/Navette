import Foundation

/// The transfer queue: runs uploads and downloads with a concurrency limit per server, and keeps every safety rule in one place.
///
/// - An upload goes to a hidden partial file next to the target and is renamed over it once its size is verified.
/// - A download goes to a `.navette-part` file; a local file it replaces goes to the Trash.
/// - A paused or failed transfer keeps its partial file and resumes from it if the source did not change.
/// - A cancelled transfer removes its partial file.
public actor TransferEngine {
    public typealias Connect = @Sendable () async throws -> any RemoteFileSystem

    private enum Stop { case pause, cancel }
    private struct CancelledByConflict: Error {}

    private struct Token: Equatable {
        var size: UInt64
        var modified: Date?
    }

    /// What one transfer remembers between attempts.
    private struct Run {
        var decided = false
        var remoteTarget: RemotePath?
        var localTarget: URL?
        /// Appending to the user's existing file (the "resume" answer to a conflict): no partial file.
        var direct = false
        var token: Token?
        var remotePartial: RemotePath?
        var localPartial: URL?
    }

    private final class Job: @unchecked Sendable {
        let item: TransferItem
        let serverKey: String
        let serverName: String
        let connect: Connect
        private let lock = NSLock()
        private var done: UInt64 = 0
        private var total: UInt64
        private var samples: [(at: ContinuousClock.Instant, bytes: UInt64)] = []
        private var _run = Run()

        // Only touched from the engine's actor.
        var state: TransferState = .queued
        var task: Task<Void, Never>?
        var stop: Stop?

        init(item: TransferItem, serverKey: String, serverName: String, connect: @escaping Connect) {
            self.item = item
            self.serverKey = serverKey
            self.serverName = serverName
            self.connect = connect
            total = item.size ?? 0
        }

        var run: Run {
            get { lock.withLock { _run } }
            set { lock.withLock { _run = newValue } }
        }

        func begin(total: UInt64, done: UInt64) {
            lock.withLock {
                self.total = total
                self.done = done
                samples = [(.now, done)]
            }
        }

        func add(_ count: Int) {
            lock.withLock {
                done += UInt64(count)
                let now = ContinuousClock.now
                if let last = samples.last, now - last.at < .milliseconds(100) { return }
                samples.append((now, done))
                samples.removeAll { now - $0.at > .seconds(3) }
            }
        }

        func snapshot() -> TransferSnapshot {
            lock.withLock {
                var speed = 0.0
                if state == .running, let first = samples.first, let last = samples.last, last.at > first.at {
                    let elapsed = last.at - first.at
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    speed = Double(last.bytes - first.bytes) / seconds
                }
                return TransferSnapshot(item: item, state: state, bytesDone: done, bytesTotal: total, bytesPerSecond: speed, serverName: serverName)
            }
        }
    }

    private let files: any LocalFiles
    private let limiter = RateLimiter()
    private let chunkSize: Int
    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var maxConcurrent: Int
    private var policy: ConflictPolicy
    private var groupResolutions: [UUID: ConflictResolution] = [:]
    private var conflictHandler: (@Sendable (TransferConflict) async -> ConflictAnswer)?
    private var onChange: (@Sendable ([TransferSnapshot]) -> Void)?
    private var ticker: Task<Void, Never>?
    private var askTail: Task<Void, Never>?

    public init(files: any LocalFiles = DiskFiles(), maxConcurrent: Int = 2, policy: ConflictPolicy = .ask, chunkSize: Int = 256 * 1024) {
        self.files = files
        self.maxConcurrent = max(1, maxConcurrent)
        self.policy = policy
        self.chunkSize = chunkSize
    }

    // MARK: - Configuration

    public func setConflictHandler(_ handler: (@Sendable (TransferConflict) async -> ConflictAnswer)?) {
        conflictHandler = handler
    }

    public func setChangeHandler(_ handler: (@Sendable ([TransferSnapshot]) -> Void)?) {
        onChange = handler
    }

    public func setPolicy(_ policy: ConflictPolicy) {
        self.policy = policy
    }

    public func setMaxConcurrent(_ count: Int) {
        maxConcurrent = max(1, count)
        schedule()
    }

    public func setRateLimit(bytesPerSecond: Int?) async {
        await limiter.setRate(bytesPerSecond: bytesPerSecond)
    }

    // MARK: - Queue

    public func enqueue(_ items: [TransferItem], serverKey: String, serverName: String, connect: @escaping Connect) {
        for item in items where jobs[item.id] == nil {
            jobs[item.id] = Job(item: item, serverKey: serverKey, serverName: serverName, connect: connect)
            order.append(item.id)
        }
        schedule()
        emit()
    }

    public func snapshots() -> [TransferSnapshot] {
        order.compactMap { jobs[$0]?.snapshot() }
    }

    public func pause(_ id: UUID) {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .running:
            job.stop = .pause
            job.task?.cancel()
        case .queued:
            job.state = .paused
            emit()
        default: break
        }
    }

    /// Restarts a paused or failed transfer, from its partial file when that is still valid.
    public func resume(_ id: UUID) {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .paused, .failed:
            job.state = .queued
            schedule()
            emit()
        default: break
        }
    }

    public func cancel(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .running:
            job.stop = .cancel
            job.task?.cancel()
        case .queued, .paused, .failed:
            await cleanUp(job)
            job.state = .cancelled
            schedule()
            emit()
        default: break
        }
    }

    public func pauseAll() {
        for id in order { pause(id) }
    }

    public func resumeAll() {
        for id in order where jobs[id]?.state == .paused { resume(id) }
    }

    /// Removes rows that are over. A failed or paused row is cancelled first, so no partial file stays behind.
    public func remove(_ ids: [UUID]) async {
        for id in ids {
            guard let job = jobs[id], job.state != .running, job.state != .queued else { continue }
            if !job.state.isDone { await cleanUp(job) }
            jobs[id] = nil
            order.removeAll { $0 == id }
        }
        emit()
    }

    public func clearFinished() async {
        await remove(order.filter { jobs[$0]?.state.isDone == true })
    }

    /// For tests: returns once nothing is running or waiting to run.
    public func waitUntilIdle() async {
        while order.contains(where: { jobs[$0]?.state == .running || jobs[$0]?.state == .queued }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Scheduling

    private func schedule() {
        var running: [String: Int] = [:]
        for id in order {
            if let job = jobs[id], job.state == .running { running[job.serverKey, default: 0] += 1 }
        }
        for id in order {
            guard let job = jobs[id], job.state == .queued, running[job.serverKey, default: 0] < maxConcurrent else { continue }
            running[job.serverKey, default: 0] += 1
            start(job)
        }
        if ticker == nil, !running.isEmpty {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, await self.tick() else { return }
                }
            }
        }
    }

    private func tick() -> Bool {
        emit()
        if order.contains(where: { jobs[$0]?.state == .running }) { return true }
        ticker = nil
        return false
    }

    private func emit() {
        onChange?(snapshots())
    }

    private func start(_ job: Job) {
        job.state = .running
        job.stop = nil
        job.task = Task { [weak self] in
            guard let self else { return }
            var result: TransferState
            do {
                let fs = try await job.connect()
                result = try await self.execute(job, on: fs)
            } catch is CancellationError {
                result = .cancelled
            } catch is CancelledByConflict {
                result = .cancelled
            } catch let error as RemoteError {
                result = error == .cancelled ? .cancelled : .failed(error)
            } catch {
                result = .failed(.server(error.localizedDescription))
            }
            await self.finish(job, result)
        }
    }

    private func finish(_ job: Job, _ result: TransferState) async {
        var state = result
        // A stop request wins over whatever error the interruption surfaced as.
        if let stop = job.stop, result != .finished, result != .skipped {
            state = stop == .pause ? .paused : .cancelled
        }
        if state == .cancelled {
            // This runs inside the transfer's own task, which is cancelled: clean up from a fresh one.
            await Task { await self.cleanUp(job) }.value
        }
        job.state = state
        job.task = nil
        job.stop = nil
        schedule()
        emit()
    }

    /// Removes the partial file of a transfer that will not continue.
    private func cleanUp(_ job: Job) async {
        var run = job.run
        if let partial = run.localPartial { try? files.removePartial(partial) }
        if let partial = run.remotePartial, let fs = try? await job.connect() {
            try? await fs.removeFile(partial)
        }
        run.localPartial = nil
        run.remotePartial = nil
        run.token = nil
        job.run = run
    }

    // MARK: - Conflicts

    private func resolve(_ conflict: TransferConflict) async -> ConflictResolution {
        if let group = conflict.item.group, let known = groupResolutions[group] { return known }
        switch policy {
        case .overwrite: return .overwrite
        case .resume: return .resume
        case .rename: return .rename
        case .skip: return .skip
        case .ask: break
        }
        // Without anyone to ask, never destroy anything.
        guard let handler = conflictHandler else { return .skip }
        // One question at a time, so "apply to all" reaches the transfers waiting behind.
        let previous = askTail
        let question = Task<ConflictResolution, Never> { [weak self] in
            await previous?.value
            guard let self else { return .skip }
            return await self.ask(conflict, handler)
        }
        askTail = Task { _ = await question.value }
        return await question.value
    }

    private func ask(_ conflict: TransferConflict, _ handler: @Sendable (TransferConflict) async -> ConflictAnswer) async -> ConflictResolution {
        if let group = conflict.item.group, let known = groupResolutions[group] { return known }
        let answer = await handler(conflict)
        if answer.applyToAll, let group = conflict.item.group { groupResolutions[group] = answer.resolution }
        return answer.resolution
    }

    // MARK: - One transfer

    private nonisolated func execute(_ job: Job, on fs: any RemoteFileSystem) async throws -> TransferState {
        let item = job.item
        switch (item.direction, item.kind) {
        case (.upload, .directory):
            try await makeDirectories(item.remote, on: fs)
            return .finished
        case (.download, .directory):
            try files.createDirectory(item.local, exactName: item.remote.nameBytes)
            return .finished
        case (.download, .symlink(let target)):
            guard files.info(item.local) == nil else { return .skipped }
            try files.createDirectory(item.local.deletingLastPathComponent(), exactName: nil)
            try files.createSymlink(at: item.local, target: target)
            return .finished
        case (.upload, .symlink):
            return .skipped
        case (.upload, .file):
            return try await upload(job, on: fs)
        case (.download, .file):
            return try await download(job, on: fs)
        }
    }

    /// `mkdir -p`: creates what is missing, accepts what exists.
    private nonisolated func makeDirectories(_ path: RemotePath, on fs: any RemoteFileSystem) async throws {
        if path.isRoot { return }
        if let existing = try await fs.statIfExists(path) {
            guard existing.kind != .file else { throw RemoteError.alreadyExists(path.display) }
            return
        }
        try await makeDirectories(path.parent, on: fs)
        do {
            try await fs.makeDirectory(path)
        } catch RemoteError.alreadyExists {
            // Another transfer created it meanwhile.
        }
    }

    private nonisolated func upload(_ job: Job, on fs: any RemoteFileSystem) async throws -> TransferState {
        let item = job.item
        guard let source = files.info(item.local), source.kind == .file else { throw RemoteError.notFound(item.local.path) }
        let token = Token(size: source.size, modified: source.modified)
        var run = job.run

        if !run.decided {
            var target = item.remote
            var found = try await fs.statIfExists(target)
            if found == nil, target.nameBytes.contains(where: { $0 > 127 }) {
                // The same name in another Unicode normalization form is the same file: use the server's spelling.
                let key = NameComparison.key(target.nameBytes)
                if let twin = try? await fs.list(target.parent).first(where: { NameComparison.key($0.path.nameBytes) == key }) {
                    target = twin.path
                    found = twin
                }
            }
            if let existing = found {
                guard existing.kind != .directory else { throw RemoteError.alreadyExists(target.display) }
                let canResume = fs.capabilities.resumeUpload && (existing.size ?? 0) < source.size
                let conflict = TransferConflict(
                    item: item, existingSize: existing.size, existingModified: existing.modified,
                    incomingSize: source.size, incomingModified: source.modified, canResume: canResume)
                switch await resolve(conflict) {
                case .cancel: throw CancelledByConflict()
                case .skip: return .skipped
                case .overwrite: break
                case .rename:
                    var number = 2
                    let original = Array(item.remote.name.utf8) == item.remote.nameBytes ? item.remote.name : target.name
                    while try await fs.statIfExists(target) != nil {
                        target = item.remote.parent.appending(TransferNames.numbered(original, number))
                        number += 1
                    }
                case .resume:
                    if canResume { run.direct = true } else if existing.size == source.size { return .skipped }
                }
            }
            run.decided = true
            run.remoteTarget = target
        }
        let target = run.remoteTarget ?? item.remote
        let destination = run.direct ? target : TransferNames.remotePartial(for: target)

        var offset: UInt64?
        if run.direct {
            offset = try await fs.statIfExists(target)?.size.flatMap { $0 <= source.size ? $0 : nil }
        } else if run.token == token, fs.capabilities.resumeUpload,
                  let partial = try await fs.statIfExists(destination)?.size, partial <= source.size {
            offset = partial
        }
        run.token = token
        run.remotePartial = run.direct ? nil : destination
        job.run = run
        job.begin(total: source.size, done: offset ?? 0)

        if offset == nil || offset! < source.size {
            let reader = try files.reader(item.local, offset: offset ?? 0)
            defer { reader.close() }
            let writer: any RemoteWriter
            do {
                writer = try await fs.write(destination, offset: offset)
            } catch RemoteError.notFound {
                try await makeDirectories(destination.parent, on: fs)
                writer = try await fs.write(destination, offset: offset)
            }
            do {
                while let chunk = try reader.read(upTo: chunkSize) {
                    try Task.checkCancellation()
                    try await limiter.acquire(chunk.count)
                    try await writer.write(chunk)
                    job.add(chunk.count)
                }
                try Task.checkCancellation()
                try await writer.close()
            } catch {
                await writer.abort()
                throw error
            }
        }

        // Verify before the target is touched: the size on the server, and that the source did not change meanwhile.
        let written = try await fs.stat(destination).size
        let unchanged = files.info(item.local).map { Token(size: $0.size, modified: $0.modified) } == token
        guard written == source.size, unchanged else {
            if !run.direct { try? await fs.removeFile(destination) }
            run.token = nil
            run.remotePartial = nil
            job.run = run
            throw RemoteError.server(unchanged ? "The size on the server does not match: \(target.display)" : "The file changed during the transfer: \(item.local.path)")
        }
        if !run.direct {
            try await fs.rename(destination, to: target, overwrite: true)
            run.remotePartial = nil
            job.run = run
        }
        return .finished
    }

    private nonisolated func download(_ job: Job, on fs: any RemoteFileSystem) async throws -> TransferState {
        let item = job.item
        let source = try await fs.stat(item.remote)
        guard source.kind != .directory else { throw RemoteError.server("Is a directory: \(item.remote.display)") }
        // The size of a symlink is the length of its target: unknown until read.
        let expected = source.kind == .symlink ? nil : source.size
        let token = Token(size: expected ?? 0, modified: source.modified)
        var run = job.run

        if !run.decided {
            var target = item.local
            if let existing = files.info(target) {
                guard existing.kind != .directory else { throw RemoteError.alreadyExists(target.path) }
                let canResume = fs.capabilities.resumeDownload && expected != nil && existing.size < expected!
                let conflict = TransferConflict(
                    item: item, existingSize: existing.size, existingModified: existing.modified,
                    incomingSize: expected, incomingModified: source.modified, canResume: canResume)
                switch await resolve(conflict) {
                case .cancel: throw CancelledByConflict()
                case .skip: return .skipped
                case .overwrite: break
                case .rename:
                    var number = 2
                    while files.info(target) != nil {
                        target = item.local.deletingLastPathComponent().appendingPathComponent(TransferNames.numbered(item.local.lastPathComponent, number))
                        number += 1
                    }
                case .resume:
                    if canResume { run.direct = true } else if existing.size == expected { return .skipped }
                }
            }
            run.decided = true
            run.localTarget = target
        }
        let target = run.localTarget ?? item.local
        let destination = run.direct ? target : TransferNames.localPartial(for: target)

        var offset: UInt64?
        if run.direct {
            offset = files.info(target).flatMap { $0.size <= (expected ?? 0) ? $0.size : nil }
        } else if run.token == token, fs.capabilities.resumeDownload, let expected,
                  let partial = files.info(destination)?.size, partial <= expected {
            offset = partial
        }
        run.token = token
        run.localPartial = run.direct ? nil : destination
        job.run = run
        job.begin(total: expected ?? 0, done: offset ?? 0)

        try files.createDirectory(target.deletingLastPathComponent(), exactName: nil)
        if offset == nil || expected == nil || offset! < expected! {
            let reader = try await fs.read(item.remote, offset: offset ?? 0)
            do {
                let writer = try files.writer(destination, offset: offset)
                do {
                    while let chunk = try await reader.next() {
                        try Task.checkCancellation()
                        try await limiter.acquire(chunk.count)
                        try writer.write(chunk)
                        job.add(chunk.count)
                    }
                    try Task.checkCancellation()
                    try writer.close()
                } catch {
                    try? writer.close()
                    throw error
                }
            } catch {
                await reader.close()
                throw error
            }
            await reader.close()
        }

        if let expected, files.info(destination)?.size != expected {
            if !run.direct { try? files.removePartial(destination) }
            run.token = nil
            run.localPartial = nil
            job.run = run
            throw RemoteError.server("The downloaded size does not match: \(item.remote.display)")
        }
        if !run.direct {
            if files.info(target) != nil { try files.trash(target) }
            // Keep the server's exact name unless a conflict made Navette pick another one.
            try files.move(destination, to: target, exactName: target == item.local ? item.remote.nameBytes : nil)
            run.localPartial = nil
            job.run = run
        }
        return .finished
    }
}
