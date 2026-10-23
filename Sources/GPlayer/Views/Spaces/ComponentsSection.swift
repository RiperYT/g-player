import GPlayerCore
import SwiftUI

/// Windows components in a space: what's there, the recommended set, and the rest on demand.
struct ComponentsSection: View {
    @Environment(AppModel.self) private var model
    let space: Space
    @State private var installed: Set<String> = []
    @State private var failed: [String] = []
    @State private var busy = false

    var body: some View {
        let baseMissing = RuntimeCatalog.base.filter { !installed.contains($0.id) }
        let pending = model.pendingComponents[space.id] ?? []
        let installing = model.installingSpaces.contains(space.id)
        VStack(alignment: .leading, spacing: 10) {
            Text("Windows components").sectionTitle()
            Text("Runtimes games need, downloaded into this space from their makers. Games ask for more when they need them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !installed.isEmpty {
                ComponentChips(ids: installed.sorted())
            }
            if space.mayChange {
                HStack(spacing: 8) {
                    if !baseMissing.isEmpty {
                        Button("Install \(model.componentsLabel(baseMissing.map(\.id)))") { install(baseMissing.map(\.id)) }
                            .buttonStyle(.borderedProminent)
                    }
                    Menu("Add Component") {
                        ForEach(RuntimeCatalog.all.filter { !installed.contains($0.id) }) { c in
                            Button { install([c.id]) } label: {
                                Text(c.approximateBytes.map { "\(c.name) · \($0.formattedBytes)" } ?? c.name)
                            }
                            .help("\(c.summary) \(c.license).")
                        }
                    }
                    .fixedSize()
                }
                .disabled(busy || installing)
                status(pending: pending, installing: installing)
                if space.origin == .external {
                    HStack(spacing: 8) {
                        Text("You allowed G-Player to install into this space.").font(.caption).foregroundStyle(.secondary)
                        Button("Don't Allow") { model.setAllowsChanges(false, for: space) }.controlSize(.small)
                    }
                }
            } else {
                ExternalSpaceNote(space: space)
            }
            Text("Each component comes from its maker under the maker's license: Microsoft for Visual C++, DirectX, .NET and XNA, NVIDIA for PhysX, Creative Labs for OpenAL. The CJK fonts are under the SIL Open Font License.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: "\(space.id)-\(model.componentsVersion)-\(installing)") { await reload() }
    }

    @ViewBuilder private func status(pending: Set<String>, installing: Bool) -> some View {
        if installing {
            Text("Installing. Progress is at the bottom of the sidebar.").font(.caption).foregroundStyle(.secondary)
        } else if busy {
            Text("Something is running in this space. Quit it to install components.").font(.caption).foregroundStyle(.secondary)
        } else if !pending.isEmpty {
            Text("Waiting to install: \(model.componentsLabel(pending.sorted())).").font(.caption).foregroundStyle(.secondary)
        }
        if !failed.isEmpty && !installing {
            HStack(spacing: 8) {
                Label("Couldn't install \(model.componentsLabel(failed)).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try Again") { install(failed, retry: true) }.controlSize(.small).disabled(busy)
            }
        }
    }

    private func install(_ ids: [String], retry: Bool = false) {
        Task {
            await model.installComponents(ids, in: space, reason: "in “\(space.name)”", retryFailed: retry)
            await reload()
        }
    }

    private func reload() async {
        guard let paths = model.paths else { return }
        let s = space
        let result = await Task.detached { () -> (Set<String>, [String]) in
            let installer = RuntimeInstaller(paths: paths)
            return (installer.installed(in: s), installer.failed(in: s).keys.sorted())
        }.value
        installed = result.0
        failed = result.1.filter { !result.0.contains($0) }
        busy = await AppModel.isBusy(s)
    }
}

/// An external space G-Player doesn't change until the user allows it.
private struct ExternalSpaceNote: View {
    @Environment(AppModel.self) private var model
    let space: Space

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(space.allowsChanges == false
                 ? "You chose to keep this space as it is: G-Player doesn't install components or .NET (Wine Mono), change its settings or replace its graphics files."
                 : "This space belongs to \(space.originNote ?? "another app"). G-Player asks before it installs anything into it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if space.allowsChanges == false, let preset = AppPresets.preset(space.presetID), let purpose = preset.dotNetReason {
                Text(WineMono.refusedLine(program: preset.name, purpose: purpose))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Allow Changes") { model.setAllowsChanges(true, for: space) }.controlSize(.small)
        }
    }
}

private struct ComponentChips: View {
    let ids: [String]
    var body: some View {
        // A simple wrap: rows of chips.
        let names = ids.map { RuntimeCatalog.component($0)?.name ?? $0 }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: names.count, by: 3)), id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(names[i..<min(i + 3, names.count)], id: \.self) { n in
                        Label(n, systemImage: "checkmark").font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }
}
