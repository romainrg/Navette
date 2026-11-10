import NavetteCore
import SwiftUI

/// The confirmation before a remote deletion: every item that will go, their count and total size.
/// A server has no Trash, so nothing is deleted before this list has been shown.
struct DeletionSheet: View {
    let model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.deletion {
            case .counting, .none:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Listing what the selection contains…")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelDeletion() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                }
            case .ready(let tree):
                DeletionSummary(tree: tree, base: model.path)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelDeletion() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                    Button("Delete Permanently") { model.confirmDeletion() }
                        .buttonStyle(GradientButtonStyle(
                            fill: LinearGradient(colors: [Color(hex: 0xF43F5E), Color(hex: 0xBE123C)], startPoint: .top, endPoint: .bottom),
                            shadow: Color(hex: 0xBE123C)))
                }
            case .deleting(let done, let total):
                Text("Deleting…").font(.headline)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done) of \(total)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct DeletionSummary: View {
    let tree: RemoteTree
    let base: RemotePath

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill").font(.system(size: 26)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete \(tree.items.count) items from the server?").font(.headline)
                    Text("This cannot be undone: a server has no Trash.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.items) { item in
                        HStack(spacing: 6) {
                            Image(nsImage: FileIcons.icon(for: item)).resizable().frame(width: 14, height: 14)
                            Text(relative(item.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            if item.kind == .file, let size = item.size {
                                Text(Format.bytes(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 220)
            .themeCard()
            HStack {
                Text(Format.count(files: tree.fileCount, folders: tree.directoryCount)).monospacedDigit()
                Spacer()
                Text("Total: \(Format.bytes(tree.totalSize))").monospacedDigit()
            }
            .font(.callout.weight(.medium))
            if !tree.unreadable.isEmpty {
                Label("\(tree.unreadable.count) folders could not be read. They will be left in place.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func relative(_ path: RemotePath) -> String {
        guard path.isDescendant(of: base) else { return path.display }
        return String(path.display.dropFirst(base.isRoot ? 1 : base.display.count + 1))
    }
}
