import Foundation
import NavetteCore
import Observation

/// The transfers drawer's state: a mirror of the engine's queue, plus the conflict question in progress.
@MainActor @Observable
final class TransfersModel {
    struct ConflictRequest: Identifiable {
        let id = UUID()
        let conflict: TransferConflict
    }

    private(set) var snapshots: [TransferSnapshot] = []
    var drawerVisible = false
    private(set) var conflict: ConflictRequest?

    @ObservationIgnored let engine: TransferEngine
    /// Called once for each transfer that completes, so browsers can refresh.
    @ObservationIgnored var onFinished: ((TransferItem) -> Void)?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictAnswer, Never>?
    @ObservationIgnored private var reported: Set<UUID> = []

    init(engine: TransferEngine, preview: [TransferSnapshot] = [], previewConflict: TransferConflict? = nil) {
        self.engine = engine
        snapshots = preview
        drawerVisible = !preview.isEmpty
        conflict = previewConflict.map { ConflictRequest(conflict: $0) }
        Task { [weak self] in
            await engine.setChangeHandler { [weak self] snapshots in
                Task { @MainActor [weak self] in self?.apply(snapshots) }
            }
            await engine.setConflictHandler { [weak self] conflict in
                await self?.ask(conflict) ?? ConflictAnswer(.skip)
            }
        }
    }

    private func apply(_ snapshots: [TransferSnapshot]) {
        self.snapshots = snapshots
        for snapshot in snapshots where snapshot.state == .finished && !reported.contains(snapshot.id) {
            reported.insert(snapshot.id)
            onFinished?(snapshot.item)
        }
    }

    // MARK: - Queue

    func enqueue(_ items: [TransferItem], serverKey: String, serverName: String, connect: @escaping TransferEngine.Connect) {
        guard !items.isEmpty else { return }
        drawerVisible = true
        Task { await engine.enqueue(items, serverKey: serverKey, serverName: serverName, connect: connect) }
    }

    /// Waits until every listed transfer is over. Returns the first failure, if any.
    func waitForCompletion(of ids: Set<UUID>) async -> RemoteError? {
        while true {
            let states = await engine.snapshots().filter { ids.contains($0.id) }.map(\.state)
            var failure: RemoteError?
            var pending = states.count < ids.count
            for state in states {
                switch state {
                case .failed(let error): failure = failure ?? error
                case .cancelled: failure = failure ?? .cancelled
                case .finished, .skipped: break
                case .queued, .running, .paused: pending = true
                }
            }
            if let failure { return failure }
            if !pending { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func pause(_ id: UUID) { Task { await engine.pause(id) } }
    func resume(_ id: UUID) { Task { await engine.resume(id) } }
    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }
    func remove(_ id: UUID) { Task { await engine.remove([id]) } }
    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }
    func clearFinished() { Task { await engine.clearFinished() } }

    var activeCount: Int { snapshots.filter { $0.state == .running || $0.state == .queued }.count }
    var totalSpeed: Double { snapshots.reduce(0) { $0 + ($1.state == .running ? $1.bytesPerSecond : 0) } }
    var hasFinished: Bool { snapshots.contains { $0.state.isDone } }
    var hasPaused: Bool { snapshots.contains { $0.state == .paused } }

    // MARK: - Conflicts

    private func ask(_ conflict: TransferConflict) async -> ConflictAnswer {
        await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            self.conflict = ConflictRequest(conflict: conflict)
        }
    }

    func answer(_ answer: ConflictAnswer) {
        conflict = nil
        conflictContinuation?.resume(returning: answer)
        conflictContinuation = nil
    }
}
