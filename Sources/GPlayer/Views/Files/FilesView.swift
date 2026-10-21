import AppKit
import GPlayerCore
import SwiftUI

struct FileItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isFolder: Bool
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
    var isProgram: Bool { ["exe", "msi", "bat"].contains(url.pathExtension.lowercased()) }
}

/// Browses a space's files, starting at its C: drive.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var folder: URL?
    @State private var items: [FileItem] = []
    @State private var selection = Set<URL>()
    @State private var sort = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]

    private var space: Space? { model.space(model.filesSpaceID) ?? model.spaces.first }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let space {
                pathBar(space)
                Divider()
                Table(items.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                    TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 16, height: 16)
                            Text(item.name).lineLimit(1)
                        }
                    }
                    TableColumn("Size", value: \.size) { item in
                        Text(item.isFolder ? "—" : item.size.formattedBytes).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90, max: 120)
                    TableColumn("Modified") { (item: FileItem) in
                        Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "").foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 150, max: 200)
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    menu(for: urls, space: space)
                } primaryAction: { urls in
                    guard let u = urls.first, let item = items.first(where: { $0.url == u }) else { return }
                    if item.isFolder { folder = u } else if item.isProgram { model.run(u, in: space) }
                    else { NSWorkspace.shared.open(u) }
                }
            } else {
                ContentUnavailableView("No spaces yet", systemImage: "folder",
                                       description: Text("Create a space or add a game to browse its files."))
            }
        }
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { if let f = folder, let s = space, f.standardizedFileURL != s.url.standardizedFileURL { folder = f.deletingLastPathComponent() } } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(folder == nil || folder?.standardizedFileURL == space?.url.standardizedFileURL)
                .help("Enclosing folder")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Space", selection: Binding(get: { space?.id }, set: { model.filesSpaceID = $0; folder = nil })) {
                    ForEach(model.spaces) { s in Text(s.name).tag(Optional(s.id)) }
                }
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { if let f = folder ?? space?.driveC { NSWorkspace.shared.activateFileViewerSelecting([f]) } } label: {
                    Label("Show in Finder", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .task(id: [space?.id.uuidString ?? "", folder?.path ?? ""].joined()) { load() }
    }

    private func pathBar(_ space: Space) -> some View {
        let current = folder ?? space.driveC
        let crumbs = breadcrumbs(current, space: space)
        return HStack(spacing: 4) {
            ForEach(crumbs, id: \.1) { name, url in
                Button(name) { folder = url }.buttonStyle(.plain)
                    .foregroundStyle(url == crumbs.last?.1 ? .primary : .secondary)
                if url != crumbs.last?.1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            Text(current.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.path).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head).textSelection(.enabled)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// "Steam" › "C:" › "Program Files" …, starting from the space.
    private func breadcrumbs(_ url: URL, space: Space) -> [(String, URL)] {
        var result: [(String, URL)] = []
        var u = url.standardizedFileURL
        let root = space.url.standardizedFileURL
        while u.path.count >= root.path.count {
            let name = u == root ? space.name : (u == space.driveC.standardizedFileURL ? "C:" : u.lastPathComponent)
            result.insert((name, u), at: 0)
            if u == root { break }
            u = u.deletingLastPathComponent().standardizedFileURL
        }
        return result
    }

    @ViewBuilder private func menu(for urls: Set<URL>, space: Space) -> some View {
        if let u = urls.first {
            let item = items.first { $0.url == u }
            if item?.isFolder == true { Button("Open") { folder = u } }
            if item?.isProgram == true {
                Button("Run in “\(space.name)”") { model.run(u, in: space) }
                Button("Add to Library") {
                    model.addGame(Game(title: u.deletingPathExtension().lastPathComponent, spaceID: space.id,
                                       executablePath: Game.storedPath(for: u, in: space),
                                       arguments: ExecutableCandidate.chromiumArguments(for: u)))
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
            Button("Copy Mac Path") { copy(u.path) }
            Button("Copy Windows Path") { copy(space.windowsPath(for: u)) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func load() {
        guard let space else { items = []; return }
        let dir = folder ?? space.driveC
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileItem(url: u, isFolder: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0),
                            modified: v?.contentModificationDate)
        }
        selection = []
    }
}
