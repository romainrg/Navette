import NavetteCore
import SwiftUI

/// The transfer queue at the bottom of the window.
struct TransfersDrawer: View {
    let model: TransfersModel
    let reveal: @MainActor (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    ProgressRing(fraction: model.activeFraction ?? (model.hasFinished ? 1 : 0), lineWidth: 4)
                    if let fraction = model.activeFraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transfers").font(.headline)
                    if model.activeCount > 0 {
                        Text("\(model.activeCount) in progress, \(Format.speed(model.totalSpeed))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                if model.hasPaused {
                    Button("Resume All") { model.resumeAll() }
                } else if model.activeCount > 0 {
                    Button("Pause All") { model.pauseAll() }
                }
                Button("Clear Finished") { model.clearFinished() }.disabled(!model.hasFinished)
                Button { model.drawerVisible = false } label: { Image(systemName: "chevron.down") }
                    .help("Hide Transfers").accessibilityLabel("Hide Transfers")
            }
            .buttonStyle(.soft)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.snapshots.isEmpty {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down", description: Text("Drop files on a folder to upload them, or drag files to Finder to download them."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.snapshots) { snapshot in
                            TransferRow(snapshot: snapshot, model: model, reveal: reveal)
                            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }
}

private struct TransferRow: View {
    let snapshot: TransferSnapshot
    let model: TransfersModel
    let reveal: @MainActor (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: Circle())
                .shadow(color: snapshot.state == .running ? tint.end.opacity(0.45) : .clear, radius: 7, y: 3)
                .accessibilityLabel(snapshot.item.direction == .upload ? Text("Upload") : Text("Download"))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(snapshot.serverName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if snapshot.state == .running || snapshot.state == .paused || isFailed {
                    GradientBar(fraction: snapshot.fraction, tint: tint, glows: snapshot.state == .running)
                }
                Text(detail).font(.caption).foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).lineLimit(1).monospacedDigit()
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) { actions }.buttonStyle(.toolbarIcon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var isFailed: Bool {
        if case .failed = snapshot.state { return true }
        return false
    }

    private var tint: Tint {
        switch snapshot.state {
        case .finished: Theme.success
        case .failed: Theme.failure
        case .paused, .queued, .skipped, .cancelled: Theme.idle
        case .running: snapshot.item.direction == .upload ? Theme.upload : Theme.download
        }
    }

    private var symbol: String {
        switch snapshot.state {
        case .finished: "checkmark"
        case .failed: "exclamationmark"
        default: snapshot.item.direction == .upload ? "arrow.up" : "arrow.down"
        }
    }

    private var detail: String {
        let progress = String(localized: "\(Format.bytes(snapshot.bytesDone)) of \(Format.bytes(snapshot.bytesTotal))")
        switch snapshot.state {
        case .running:
            if let remaining = snapshot.secondsRemaining {
                return String(localized: "\(progress), \(Format.speed(snapshot.bytesPerSecond)), \(Format.remaining(remaining)) left")
            }
            return progress
        case .paused:
            return String(localized: "Paused, \(progress)")
        case .finished:
            return String(localized: "Done, \(Format.bytes(snapshot.bytesTotal))")
        default:
            return snapshot.state.label
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch snapshot.state {
        case .running:
            button("pause.fill", "Pause") { model.pause(snapshot.id) }
            button("xmark", "Cancel") { model.cancel(snapshot.id) }
        case .queued:
            button("xmark", "Cancel") { model.cancel(snapshot.id) }
        case .paused:
            button("play.fill", "Resume") { model.resume(snapshot.id) }
            button("xmark", "Cancel") { model.cancel(snapshot.id) }
        case .failed:
            button("arrow.clockwise", "Retry") { model.resume(snapshot.id) }
            button("xmark", "Remove") { model.remove(snapshot.id) }
        case .finished:
            if snapshot.item.direction == .download {
                button("magnifyingglass", "Show in Finder") { reveal(snapshot.item.local) }
            }
            button("xmark", "Remove") { model.remove(snapshot.id) }
        case .skipped, .cancelled:
            button("xmark", "Remove") { model.remove(snapshot.id) }
        }
    }

    private func button(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(label).accessibilityLabel(label)
    }
}

/// The destination already exists: what is there, what is coming, and what to do.
struct ConflictSheet: View {
    let conflict: TransferConflict
    let answer: (ConflictAnswer) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                GradientTile(tint: Theme.upload, symbol: "doc.on.doc.fill", size: 40, glows: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(conflict.item.name)” already exists").font(.title3.bold())
                    Text(conflict.item.direction == .upload ? "On the server, in “\(conflict.item.remote.parent.display)”." : "On this Mac, in “\(conflict.item.local.deletingLastPathComponent().path)”.")
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            HStack(spacing: 12) {
                side("Existing", size: conflict.existingSize, date: conflict.existingModified)
                Image(systemName: "arrow.left").foregroundStyle(.secondary)
                side("New", size: conflict.incomingSize, date: conflict.incomingModified)
            }
            if conflict.item.direction == .download {
                Text("A file that gets replaced goes to the Trash.").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Apply to all conflicts of this transfer", isOn: $applyToAll).font(.callout)
            HStack(spacing: 8) {
                Button("Stop") { answer(ConflictAnswer(.cancel)) }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { answer(ConflictAnswer(.skip, applyToAll: applyToAll)) }.buttonStyle(.soft)
                Button("Rename") { answer(ConflictAnswer(.rename, applyToAll: applyToAll)) }.buttonStyle(.soft)
                if conflict.canResume {
                    Button("Resume") { answer(ConflictAnswer(.resume, applyToAll: applyToAll)) }.buttonStyle(.soft)
                }
                Button("Overwrite") { answer(ConflictAnswer(.overwrite, applyToAll: applyToAll)) }.buttonStyle(.gradient)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func side(_ title: LocalizedStringKey, size: UInt64?, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(size.map(Format.bytes) ?? "--").font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(date.map(Format.date) ?? "--").font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }
}
