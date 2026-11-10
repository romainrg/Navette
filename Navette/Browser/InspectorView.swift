import NavetteCore
import SwiftUI

/// Details of the selected item, and its permissions as checkboxes and in octal.
struct InspectorView: View {
    let model: BrowserModel

    var body: some View {
        ScrollView {
            if let item = model.singleSelection {
                ItemInspector(item: item, model: model).id(item)
            } else {
                ContentUnavailableView(
                    model.selection.isEmpty ? "No selection" : "\(model.selection.count) items selected",
                    systemImage: "info.circle",
                    description: Text("Select one item to see its details."))
                    .padding(.top, 60)
            }
        }
        .background(Theme.barFill)
    }
}

private struct ItemInspector: View {
    let item: RemoteItem
    let model: BrowserModel
    @State private var permissions: PermissionSet
    @State private var octal: String
    @State private var recursive = false

    init(item: RemoteItem, model: BrowserModel) {
        self.item = item
        self.model = model
        let set = PermissionSet(bits: item.permissions ?? 0)
        _permissions = State(initialValue: set)
        _octal = State(initialValue: set.octal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(for: item)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).lineLimit(3).textSelection(.enabled)
                    Text(Format.kind(of: item)).font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if item.kind != .directory, let size = item.size {
                    row("Size", "\(Format.bytes(size)) (\(size.formatted()) bytes)")
                }
                if let modified = item.modified { row("Modified", Format.date(modified)) }
                if let owner = item.owner { row("Owner", owner) }
                if let group = item.group { row("Group", group) }
                if let target = item.linkTarget { row("Points to", target) }
                row("Where", item.path.parent.display)
            }

            if model.capabilities.permissions, item.permissions != nil, item.kind != .symlink {
                Divider()
                permissionEditor
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                Text(model.url(of: item)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                Button("Copy URL") { model.copyURL(of: item) }.buttonStyle(.soft).controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private var permissionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "")
                    Text("Read").font(.caption).foregroundStyle(.secondary)
                    Text("Write").font(.caption).foregroundStyle(.secondary)
                    Text("Execute").font(.caption).foregroundStyle(.secondary)
                }
                scopeRow("Owner", .owner)
                scopeRow("Group", .group)
                scopeRow("Others", .others)
            }
            HStack(spacing: 8) {
                Text("Octal").font(.callout)
                TextField(String("644"), text: $octal)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 64)
                    .onChange(of: octal) { _, value in
                        if let parsed = PermissionSet(octal: value), parsed != permissions { permissions = parsed }
                    }
                Text(permissions.symbolic).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if item.isDirectory {
                Toggle("Apply to enclosed items", isOn: $recursive).font(.callout)
            }
            Button("Apply") { model.setPermissions(permissions, of: item, recursive: recursive) }
                .buttonStyle(.gradient(model.bookmark.protocol.tint))
                .controlSize(.small)
                .disabled(permissions.bits == (item.permissions ?? 0) && !recursive)
        }
    }

    private func scopeRow(_ label: LocalizedStringKey, _ scope: PermissionSet.Scope) -> some View {
        GridRow {
            Text(label).font(.callout)
            ForEach(PermissionSet.Access.allCases, id: \.rawValue) { access in
                Toggle(String(), isOn: Binding(
                    get: { permissions.allows(access, for: scope) },
                    set: { allowed in
                        permissions.set(access, for: scope, to: allowed)
                        octal = permissions.octal
                    }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
        }
    }
}
