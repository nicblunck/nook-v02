import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// Sidebar, canvas, and an inspector that stays out of the way until asked for.
struct LibraryWindow: View {
    @Bindable var model: LibraryModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
            #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            #endif
        } detail: {
            BrowseView(model: model)
        }
        .environment(\.thumbnailLoader, model.library.thumbnails)
        .inspector(isPresented: $model.isInspectorPresented) {
            InfoPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .overlay(alignment: .bottom) {
            if let progress = model.importProgress {
                ImportProgressBar(progress: progress)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.importProgress?.completed)
        .environment(model)
    }
}

/// Non-blocking progress for a large import; the rest of the app stays usable.
struct ImportProgressBar: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Importing \(progress.completed + 1) of \(progress.total)")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            if let name = progress.currentItemName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 12, y: 4)
    }
}

struct NookCommands: Commands {
    var body: some Commands {
        // Placeholder group so the menu keeps a stable shape while the full
        // keyboard map lands with the rest of Phase 5.
        CommandGroup(replacing: .newItem) {}
    }
}
