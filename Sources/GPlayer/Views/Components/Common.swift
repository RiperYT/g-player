import AppKit
import GPlayerCore
import SwiftUI

/// The big dashed target shown when a list is empty: drop a game here.
struct DropZone: View {
    let title: String
    let message: String
    var targeted = false
    var actions: AnyView? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 30, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actions { actions.padding(.top, 4) }
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(targeted ? Color.accentColor.opacity(0.06) : .clear))
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// Long work in progress, pinned to the bottom of the sidebar.
struct ActivityPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.activities.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.activities) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(a.title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if model.canCancel(a.id) {
                                Button { model.cancel(a.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help(a.stopHelp).accessibilityLabel("Stop")
                            }
                        }
                        if let p = a.progress { ProgressView(value: p).controlSize(.small) }
                        else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                        Text(model.message(of: a)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let note = a.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
    }
}

/// Why a folder can't be used: a warning icon and the reason.
struct PathWarning: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
    }
}

/// A path in monospace with a Finder button.
struct PathRow: View {
    let url: URL
    var body: some View {
        HStack(spacing: 6) {
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "arrow.right.circle.fill")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
        }
    }
}

enum Panels {
    /// Pick a game folder, archive, .exe or .msi.
    @MainActor static func chooseGameSource() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a game folder, an archive (zip, rar, 7z) or an installer (.exe, .msi)."
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func chooseFolder(message: String, start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func chooseFile(message: String, start: URL?, types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = message
        panel.directoryURL = start
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Double {
    /// 3h 20m, 45m, under a minute.
    var playtime: String {
        let minutes = Int(self / 60)
        if minutes < 1 { return "Under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
