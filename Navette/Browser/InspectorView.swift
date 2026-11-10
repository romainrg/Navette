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
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 8) {
                if item.kind != .directory, let size = item.size {
                    row("Size", "\(Format.bytes(size)) (\(size.formatted()) bytes)")
                }
                if let modified = item.modified { row("Modified", Format.date(modified)) }
                if let owner = item.owner { row("Owner", owner) }
                if let group = item.group { row("Group", group) }
                if let target = item.linkTarget { row("Points to", target) }
                row("Where", item.path.parent.display)
            }
            .padding(.horizontal, 4)

            if model.capabilities.permissions, item.permissions != nil, item.kind != .symlink {
                permissionEditor
                    .padding(12)
                    .themeCard()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Address").font(.subheadline.weight(.semibold))
                Text(model.url(of: item))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeCard()
                Button("Copy URL") { model.copyURL(of: item) }.buttonStyle(.soft).controlSize(.small)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The item on a gradient card, its kind's color glowing in the corner.
    private var header: some View {
        let kind = FileKind(item)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let tile = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.18), in: tile)
                .overlay(tile.strokeBorder(.white.opacity(0.35)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(3).textSelection(.enabled)
                Text(Format.kind(of: item)).font(.callout).foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.hero
                RadialGradient(colors: [kind.tint.start.opacity(0.55), kind.tint.start.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 180)
            }
            .clipShape(shape)
        }
        .shadow(color: Color(hex: 0x4338CA).opacity(0.25), radius: 14, y: 8)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private var permissionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Permissions").font(.subheadline.weight(.semibold))
                Spacer()
                Text(permissions.symbolic).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "")
                    ForEach(PermissionSet.Access.allCases, id: \.rawValue) { access in
                        Text(title(of: access)).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.center)
                    }
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
                Spacer()
                Button("Apply") { model.setPermissions(permissions, of: item, recursive: recursive) }
                    .buttonStyle(.gradient)
                    .controlSize(.small)
                    .disabled(permissions.bits == (item.permissions ?? 0) && !recursive)
            }
            if item.isDirectory {
                Toggle("Apply to enclosed items", isOn: $recursive).font(.callout)
            }
        }
    }

    private func title(of access: PermissionSet.Access) -> LocalizedStringKey {
        switch access {
        case .read: "Read"
        case .write: "Write"
        case .execute: "Execute"
        }
    }

    private func scopeRow(_ label: LocalizedStringKey, _ scope: PermissionSet.Scope) -> some View {
        GridRow {
            Text(label).font(.callout)
            ForEach(PermissionSet.Access.allCases, id: \.rawValue) { access in
                Toggle(isOn: Binding(
                    get: { permissions.allows(access, for: scope) },
                    set: { allowed in
                        permissions.set(access, for: scope, to: allowed)
                        octal = permissions.octal
                    })) {
                    Text(label) + Text(verbatim: ", ") + Text(title(of: access))
                }
                .toggleStyle(PermissionToggleStyle())
            }
        }
    }
}
