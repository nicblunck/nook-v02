#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

// MARK: - The outline

/// The Mac sidebar: a real `NSOutlineView`, the control every Mac sidebar is.
///
/// SwiftUI's `List` wraps one of these, but reaches it through a layer of its
/// own that gets the things a sidebar is for wrong — where a drop lands, which
/// row lights up for it, who holds the keyboard. Owning the outline directly
/// gets all of that from the system: drop targeting and its highlight,
/// spring-loaded folders, auto-scroll during a drag, left and right to open
/// and close, and a selection painted by the control that actually has focus.
///
/// The iPad keeps the SwiftUI list; only the rows' meaning is shared, through
/// the model. Everything SwiftUI around the outline — the footer, the toolbar,
/// the naming prompts, the appearance editor — stays where it was.
struct MacSidebar: NSViewRepresentable {
    let model: LibraryModel

    // Read here, in a SwiftUI body, so a change to any of them re-runs
    // `updateNSView`. The outline never observes the model itself.
    let folderTree: [FolderNode]
    let collections: [CollectionSnapshot]
    let tags: [TagSnapshot]
    let counts: [ScopeCountKey: Int]
    let presentMediaKinds: Set<ObjectKind>
    let destination: LibraryDestination
    let expandedFolders: Set<FolderID>
    let wantsKeyboard: Bool
    let keyboardFocusRequest: Int

    /// Raises the appearance editor, which is SwiftUI state the outline cannot
    /// hold.
    let onEditAppearance: (AppearanceTarget) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onEditAppearance: onEditAppearance)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        let column = NSTableColumn(identifier: .init("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsColumnSelection = false
        // Typing a name to jump to a row was ruled out for this sidebar.
        outline.allowsTypeSelect = false
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 12
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.registerForDraggedTypes(
            [.nookFolder, .nookObject, .fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
        )
        // Folders move within Nook. Nothing here is a file, so nothing here
        // leaves the app.
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.onKey = { [coordinator = context.coordinator] event in coordinator.handle(event) }
        outline.onBecomeFirstResponder = { [coordinator = context.coordinator] in coordinator.outlineTookKeyboard() }
        outline.onMovedToWindow = { [coordinator = context.coordinator] in coordinator.windowIsReady() }
        outline.menuProvider = { [coordinator = context.coordinator] row in coordinator.menu(forRow: row) }
        context.coordinator.outline = outline

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // The sidebar runs up under the toolbar; the scroll view keeps its
        // content clear of it, the way every Mac sidebar does.
        scrollView.automaticallyAdjustsContentInsets = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onEditAppearance = onEditAppearance
        context.coordinator.apply(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.outline = nil
    }
}

// MARK: - Items

/// One row of the sidebar, as the outline holds it.
///
/// A class rather than a value, because `NSOutlineView` knows its items by
/// identity: the same object has to stand for the same place across every
/// update, or expansion and selection are lost each time the library changes.
/// The place is fixed at creation; what the row shows about it is not.
final class SidebarItem: NSObject {
    enum ID: Hashable {
        case section(SidebarSection)
        case destination(LibraryDestination)
        case placeholder(SidebarSection)
    }

    let id: ID
    var row: SidebarRow
    var children: [SidebarItem]

    init(id: ID, row: SidebarRow, children: [SidebarItem] = []) {
        self.id = id
        self.row = row
        self.children = children
    }

    var isSection: Bool {
        if case .section = id { return true }
        return false
    }

    var folderID: FolderID? {
        if case .destination(.scope(.folder(let id))) = id { return id }
        return nil
    }
}

enum SidebarSection: Hashable, CaseIterable {
    case library, folders, collections, mediaTypes, tags

    var title: String {
        switch self {
        case .library: "Library"
        case .folders: "Folders"
        case .collections: "Collections"
        case .mediaTypes: "Media Types"
        case .tags: "Tags"
        }
    }

    var addAction: (title: String, symbol: String)? {
        switch self {
        case .folders: ("New Folder…", "folder.badge.plus")
        case .collections: ("New Collection…", "rectangle.stack.badge.plus")
        case .tags: ("New Tag…", "tag")
        case .library, .mediaTypes: nil
        }
    }
}

/// What a row shows, and what it stands for.
struct SidebarRow: Equatable {
    enum Icon: Equatable {
        case symbol(String, colorHex: String?)
        case emoji(String)
    }

    /// The entity behind the row, for its menu.
    enum Subject: Equatable {
        case folder(FolderSnapshot)
        case collection(CollectionSnapshot)
        case tag(TagSnapshot)
    }

    var title: String
    var icon: Icon?
    var count: Int?
    var isHidden = false
    var isLocked = false
    /// True while a locked folder is currently authenticated — the badge
    /// still marks it as a locked place, but with the door standing open.
    var isLockOpen = false
    /// Nil for a section header or a placeholder: nothing to navigate to.
    var destination: LibraryDestination?
    var dropTarget: DropTarget?
    var draggableFolder: FolderID?
    var subject: Subject?
    var isPlaceholder = false

    static func section(_ section: SidebarSection) -> SidebarRow {
        SidebarRow(title: section.title, dropTarget: section == .folders ? .folder(nil) : nil)
    }

    static func placeholder(_ text: String) -> SidebarRow {
        SidebarRow(title: text, isPlaceholder: true)
    }
}

// MARK: - Coordinator

extension MacSidebar {
    @MainActor
    final class Coordinator: NSObject {
        let model: LibraryModel
        var onEditAppearance: (AppearanceTarget) -> Void
        weak var outline: SidebarOutlineView?

        private var roots: [SidebarItem] = []
        /// Raised while the outline is being brought into line with the
        /// model, so what the outline reports back is not mistaken for
        /// something the person did.
        private var isApplying = false
        private var appliedFocusRequest = -1
        private var wantsKeyboard = false

        init(model: LibraryModel, onEditAppearance: @escaping (AppearanceTarget) -> Void) {
            self.model = model
            self.onEditAppearance = onEditAppearance
        }

        // MARK: Bringing the outline into line

        func apply(_ sidebar: MacSidebar) {
            guard let outline else { return }
            isApplying = true
            defer { isApplying = false }

            let fresh = Self.tree(from: sidebar)
            if roots.isEmpty {
                roots = fresh
                outline.reloadData()
                for section in roots { outline.expandItem(section) }
            } else {
                outline.beginUpdates()
                merge(fresh, into: nil, outline: outline)
                outline.endUpdates()
            }

            syncExpansion(with: sidebar.expandedFolders, outline: outline)
            select(sidebar.destination, outline: outline)

            wantsKeyboard = sidebar.wantsKeyboard
            if sidebar.keyboardFocusRequest != appliedFocusRequest {
                appliedFocusRequest = sidebar.keyboardFocusRequest
                if sidebar.wantsKeyboard { takeKeyboard() }
            }
        }

        /// Reconciles one level of the tree: rows that are still there keep
        /// their objects and take their new contents, rows that have gone are
        /// removed, new ones inserted — so the outline animates the change
        /// rather than being rebuilt around it.
        private func merge(_ fresh: [SidebarItem], into parent: SidebarItem?, outline: NSOutlineView) {
            let existing = parent?.children ?? roots
            let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var merged: [SidebarItem] = []
            var changed: [SidebarItem] = []
            for item in fresh {
                if let kept = byID[item.id] {
                    let wasExpandable = !kept.children.isEmpty
                    if kept.row != item.row || wasExpandable != !item.children.isEmpty { changed.append(kept) }
                    // The identity is kept for the outline's sake — its
                    // expansion state and selection track this object — but
                    // what it shows has to catch up, or a row whose content
                    // changed without its position or children changing
                    // would reload showing the same stale row it always had.
                    kept.row = item.row
                    merged.append(kept)
                } else {
                    merged.append(item)
                }
            }

            let difference = merged.map(\.id).difference(from: existing.map(\.id))
            let removed = IndexSet(difference.removals.compactMap { if case .remove(let offset, _, _) = $0 { offset } else { nil } })
            let inserted = IndexSet(difference.insertions.compactMap { if case .insert(let offset, _, _) = $0 { offset } else { nil } })

            if let parent { parent.children = merged } else { roots = merged }
            if !removed.isEmpty { outline.removeItems(at: removed, inParent: parent, withAnimation: .effectFade) }
            if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: parent, withAnimation: .effectFade) }
            for item in changed { outline.reloadItem(item, reloadChildren: false) }

            // Children of kept rows are merged in turn; new rows arrived with
            // theirs already in place.
            for (kept, item) in zip(merged, fresh) where byID[item.id] != nil {
                merge(item.children, into: kept, outline: outline)
            }

            // A section that has just appeared — Tags, when the first tag is
            // made — opens the way the others did at launch.
            for item in merged where item.isSection && byID[item.id] == nil {
                outline.expandItem(item)
            }
        }

        private func syncExpansion(with expanded: Set<FolderID>, outline: NSOutlineView) {
            func walk(_ items: [SidebarItem]) {
                for item in items {
                    if let folder = item.folderID, !item.children.isEmpty {
                        let shouldBeOpen = expanded.contains(folder)
                        if shouldBeOpen != outline.isItemExpanded(item) {
                            shouldBeOpen ? outline.expandItem(item) : outline.collapseItem(item)
                        }
                    }
                    walk(item.children)
                }
            }
            walk(roots)
        }

        private func select(_ destination: LibraryDestination, outline: NSOutlineView) {
            guard let item = item(for: destination) else {
                outline.deselectAll(nil)
                return
            }
            // A place inside a closed folder is opened up to, as the Finder
            // does; the folders opened on the way are recorded once this
            // update is over, since it is the model's state being changed.
            var opened: [FolderID] = []
            for ancestor in ancestors(of: item) where !outline.isItemExpanded(ancestor) {
                outline.expandItem(ancestor)
                if let folder = ancestor.folderID { opened.append(folder) }
            }
            if !opened.isEmpty {
                let model = model
                Task { @MainActor in model.expandedFolders.formUnion(opened) }
            }
            let row = outline.row(forItem: item)
            guard row >= 0, outline.selectedRow != row else { return }
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }

        // MARK: The keyboard

        /// The keys the sidebar means something particular by, answered by the
        /// model exactly as before. Up and down are the outline's own.
        func handle(_ event: NSEvent) -> Bool {
            guard event.heldModifiers.subtracting(.shift).isEmpty else { return false }
            switch event.keyCode {
            case MacKey.left: model.collapseOrGoToParent()
            case MacKey.right: model.expandOrEnterCanvas()
            case MacKey.return, MacKey.keypadEnter: model.enterCanvas()
            case MacKey.tab, MacKey.escape: model.focus(.canvas)
            default: return false
            }
            return true
        }

        func outlineTookKeyboard() {
            // Clicking a row is another way of saying the keyboard belongs
            // here. Being handed it by the model is not news to the model.
            guard !isApplying, !isTakingKeyboard else { return }
            model.focus(.sidebar)
        }

        private var isTakingKeyboard = false

        private func takeKeyboard() {
            guard let outline, let window = outline.window else { return }
            isTakingKeyboard = true
            defer { isTakingKeyboard = false }
            window.makeFirstResponder(outline)
        }

        /// The first update usually runs before there is a window to be first
        /// responder in.
        func windowIsReady() {
            if wantsKeyboard { takeKeyboard() }
        }

        // MARK: Finding rows

        private func item(for destination: LibraryDestination) -> SidebarItem? {
            func find(in items: [SidebarItem]) -> SidebarItem? {
                for item in items {
                    if item.row.destination == destination { return item }
                    if let found = find(in: item.children) { return found }
                }
                return nil
            }
            return find(in: roots)
        }

        private func ancestors(of target: SidebarItem) -> [SidebarItem] {
            func path(_ items: [SidebarItem], _ trail: [SidebarItem]) -> [SidebarItem]? {
                for item in items {
                    if item === target { return trail }
                    if let found = path(item.children, trail + [item]) { return found }
                }
                return nil
            }
            return path(roots, []) ?? []
        }

        // MARK: Building the tree

        private static func tree(from sidebar: MacSidebar) -> [SidebarItem] {
            var roots: [SidebarItem] = []

            roots.append(SidebarItem(id: .section(.library), row: .section(.library), children: [
                systemRow(.home, title: "All", symbol: "square.grid.2x2",
                          count: sidebar.counts[.allObjects]),
                // Inbox and Favorites are places a drop means something:
                // dropping on Inbox files something out of every folder,
                // dropping on Favorites stars it. Recent and All are queries
                // over the library rather than places in it, so nothing can
                // be put into them.
                systemRow(.scope(.inbox), title: "Inbox", symbol: "tray",
                          count: sidebar.counts[.inbox], dropTarget: .folder(nil)),
                systemRow(.scope(.recent), title: "Recent", symbol: "clock"),
                systemRow(.scope(.favorites), title: "Favorites", symbol: "star",
                          count: sidebar.counts[.favorites], dropTarget: .favorites),
            ]))

            // The root of the hierarchy. A folder dropped on the header comes
            // out to the top level; an object dropped there comes out of every
            // folder, which is to say into the Inbox.
            let folders = sidebar.folderTree.isEmpty
                ? [SidebarItem(id: .placeholder(.folders), row: .placeholder("No folders yet"))]
                : sidebar.folderTree.map(folderItem)
            roots.append(SidebarItem(id: .section(.folders), row: .section(.folders), children: folders))

            let collections = sidebar.collections.isEmpty
                ? [SidebarItem(id: .placeholder(.collections), row: .placeholder("No collections yet"))]
                : sidebar.collections.map(collectionItem)
            roots.append(SidebarItem(id: .section(.collections), row: .section(.collections), children: collections))

            if !sidebar.presentMediaKinds.isEmpty {
                let kinds = ObjectKind.mediaTypes.filter(sidebar.presentMediaKinds.contains)
                roots.append(SidebarItem(id: .section(.mediaTypes), row: .section(.mediaTypes),
                                         children: kinds.map { kind in
                    SidebarItem(id: .destination(.scope(.kind(kind))), row: SidebarRow(
                        title: kind.pluralDisplayName,
                        icon: .symbol(kind.symbolName, colorHex: nil),
                        destination: .scope(.kind(kind))
                    ))
                }))
            }

            let tags = sidebar.tags.isEmpty
                ? [SidebarItem(id: .placeholder(.tags), row: .placeholder("No tags yet"))]
                : sidebar.tags.map(tagItem)
            roots.append(SidebarItem(id: .section(.tags), row: .section(.tags), children: tags))
            return roots
        }

        private static func systemRow(_ destination: LibraryDestination,
                                      title: String,
                                      symbol: String,
                                      count: Int? = nil,
                                      dropTarget: DropTarget? = nil) -> SidebarItem {
            SidebarItem(id: .destination(destination), row: SidebarRow(
                title: title,
                icon: .symbol(symbol, colorHex: nil),
                count: count,
                destination: destination,
                dropTarget: dropTarget
            ))
        }

        private static func folderItem(_ node: FolderNode) -> SidebarItem {
            let folder = node.folder
            let destination = LibraryDestination.scope(.folder(folder.id))
            return SidebarItem(id: .destination(destination), row: SidebarRow(
                title: folder.name,
                icon: icon(for: folder.appearance, fallback: "folder"),
                isHidden: folder.isHidden,
                isLocked: folder.isLocked,
                isLockOpen: folder.isLocked && folder.visibility == .full,
                destination: destination,
                // Dropping onto a folder moves: this is the true hierarchy, so
                // the drop is a real relocation. Files from outside are
                // imported into it.
                dropTarget: .folder(folder.id),
                draggableFolder: folder.id,
                subject: .folder(folder)
            ), children: node.children.map(folderItem))
        }

        private static func collectionItem(_ collection: CollectionSnapshot) -> SidebarItem {
            let destination = LibraryDestination.scope(.collection(collection.id))
            return SidebarItem(id: .destination(destination), row: SidebarRow(
                title: collection.name,
                icon: icon(for: collection.appearance, fallback: "rectangle.stack"),
                count: collection.memberCount > 0 ? collection.memberCount : nil,
                isHidden: collection.isHidden,
                destination: destination,
                // A drop here adds a membership. Nothing moves.
                dropTarget: .collection(collection.id),
                subject: .collection(collection)
            ))
        }

        /// A tag is a row of its own here, as it is in the Finder: a row is
        /// what the outline can light up for a drop.
        private static func tagItem(_ tag: TagSnapshot) -> SidebarItem {
            let destination = LibraryDestination.scope(.tag(tag.id))
            return SidebarItem(id: .destination(destination), row: SidebarRow(
                title: tag.name,
                icon: icon(for: tag.appearance, fallback: "tag.fill"),
                count: tag.objectCount > 0 ? tag.objectCount : nil,
                destination: destination,
                dropTarget: .tag(tag.id),
                subject: .tag(tag)
            ))
        }

        private static func icon(for appearance: EntityAppearance, fallback: String) -> SidebarRow.Icon {
            if let emoji = appearance.emoji { return .emoji(emoji) }
            return .symbol(appearance.symbolName ?? fallback, colorHex: appearance.colorHex)
        }
    }
}

// MARK: - Data source and delegate

extension MacSidebar.Coordinator: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func items(under item: Any?) -> [SidebarItem] {
        (item as? SidebarItem)?.children ?? roots
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        items(under: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items(under: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !items(under: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if let item = item as? SidebarItem, case .section = item.id { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !items(under: item).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.row.destination != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if case .section(let section) = item.id {
            let identifier = NSUserInterfaceItemIdentifier("section")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarSectionCell
                ?? SidebarSectionCell(identifier: identifier)
            cell.show(section) { [weak self] in self?.addItem(to: section) }
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarRowCell
            ?? SidebarRowCell(identifier: identifier)
        cell.show(item.row)
        return cell
    }

    private func addItem(to section: SidebarSection) {
        switch section {
        case .folders:
            model.editingAppearance = .newFolder(parent: nil)
        case .collections:
            model.editingAppearance = .newCollection(adding: [])
        case .tags:
            model.editingAppearance = .newTag()
        case .library, .mediaTypes:
            break
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying, let outline,
              let item = outline.item(atRow: outline.selectedRow) as? SidebarItem,
              let destination = item.row.destination
        else { return }
        // A locked folder authenticates before the canvas lands on it, rather
        // than navigating straight to the door.
        if case .scope(.folder(let id)) = destination {
            Task { await model.openFolder(id) }
        } else {
            model.navigate(to: destination)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplying, let folder = (notification.userInfo?["NSObject"] as? SidebarItem)?.folderID else { return }
        model.expandedFolders.insert(folder)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplying, let folder = (notification.userInfo?["NSObject"] as? SidebarItem)?.folderID else { return }
        model.expandedFolders.remove(folder)
    }

    // MARK: Dragging out

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let folder = (item as? SidebarItem)?.row.draggableFolder,
              let data = try? JSONEncoder().encode(FolderTransfer(id: folder))
        else { return nil }
        // The same bytes SwiftUI writes for a `FolderTransfer`, so a folder
        // dragged out of the sidebar can still land on a folder card in the
        // canvas.
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .nookFolder)
        return pasteboardItem
    }

    // MARK: Dropping in

    /// The place a drop at this position would land, or nil where there is
    /// none.
    ///
    /// Between two rows counts as on their parent: there is no manual order
    /// here to insert into, so a drop between two subfolders is a drop into
    /// the folder that holds them, and one between two top-level folders is a
    /// drop out to the root.
    private func dropPlace(item: Any?, childIndex: Int) -> SidebarItem? {
        guard let item = item as? SidebarItem, item.row.dropTarget != nil else { return nil }
        return item
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let place = dropPlace(item: item, childIndex: index),
              let target = place.row.dropTarget,
              let payload = SidebarDropRules.payload(on: info.draggingPasteboard)
        else { return [] }
        let verdict = SidebarDropRules.verdict(for: payload, on: target, model: model)
        guard verdict.takesDrop else { return [] }
        // Always *on* the place, never between its children: that is what
        // lights the row rather than drawing an insertion line.
        outlineView.setDropItem(place, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return verdict == .move ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: any NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let place = dropPlace(item: item, childIndex: index),
              let target = place.row.dropTarget,
              let payload = SidebarDropRules.payload(on: info.draggingPasteboard),
              SidebarDropRules.verdict(for: payload, on: target, model: model).takesDrop
        else { return false }
        let pasteboard = info.draggingPasteboard
        let model = model
        Task { @MainActor in
            let items = await LibraryDropItem.items(on: pasteboard)
            guard !items.isEmpty else { return }
            await model.accept(items, at: target)
        }
        return true
    }

    // MARK: Menus

    func menu(forRow row: Int) -> NSMenu? {
        guard let outline, row >= 0, let item = outline.item(atRow: row) as? SidebarItem,
              let subject = item.row.subject
        else { return nil }
        let menu = NSMenu()
        switch subject {
        case .folder(let folder):
            menu.add("Rename…") { [model] in model.namingPrompt = .renameFolder(folder.id) }
            menu.add("New Subfolder…") { [model] in
                model.editingAppearance = .newFolder(parent: folder.id)
            }
            menu.add("Customize…") { [onEditAppearance] in
                onEditAppearance(AppearanceTarget(reference: .folder(folder.id), title: folder.name,
                                                  appearance: folder.appearance))
            }
            menu.addItem(.separator())
            addPrivacyItems(to: menu, for: folder,
                            hide: { [model] in await model.setHidden($0, forFolder: folder) },
                            lock: { [model] in await model.setLocked($0, forFolder: folder) })
            menu.addItem(.separator())
            menu.add("Delete Folder") { [model] in Task { await model.deleteFolder(folder.id) } }
        case .collection(let collection):
            menu.add("Rename…") { [model] in model.namingPrompt = .renameCollection(collection.id) }
            menu.add("Customize…") { [onEditAppearance] in
                onEditAppearance(AppearanceTarget(reference: .collection(collection.id), title: collection.name,
                                                  appearance: collection.appearance))
            }
            menu.addItem(.separator())
            // A hidden collection conceals the collection itself. What it
            // gathers stays exactly as reachable as it was: the true folder
            // hierarchy is where storage privacy — including locking — lives.
            addHideItem(to: menu, for: collection,
                       hide: { [model] in await model.setHidden($0, forCollection: collection) })
            menu.addItem(.separator())
            menu.add("Delete Collection") { [model] in Task { await model.deleteCollection(collection.id) } }
        case .tag(let tag):
            menu.add("Rename…") { [model] in model.namingPrompt = .renameTag(tag.id) }
            menu.add("Customize…") { [onEditAppearance] in
                onEditAppearance(AppearanceTarget(reference: .tag(tag.id), title: tag.name,
                                                  appearance: tag.appearance))
            }
            menu.addItem(.separator())
            menu.add("Delete Tag") { [model] in Task { await model.deleteTag(tag.id) } }
        }
        return menu
    }

    /// Hide and Lock as a pair of menu items, offered on what the place is in
    /// its own right — a subfolder of a hidden folder is hidden without being
    /// hidden itself, and only the ancestor can lift that.
    private func addPrivacyItems(to menu: NSMenu,
                                 for item: some PrivacyBearing,
                                 hide: @escaping (Bool) async -> Void,
                                 lock: @escaping (Bool) async -> Void) {
        addHideItem(to: menu, for: item, hide: hide)
        let locked = item.isExplicitlyLocked
        menu.add(locked ? "Unlock" : "Lock") { Task { await lock(!locked) } }
    }

    /// Hide alone, for entities — collections — that can be hidden but never
    /// locked.
    private func addHideItem(to menu: NSMenu,
                             for item: some PrivacyBearing,
                             hide: @escaping (Bool) async -> Void) {
        let hidden = item.isExplicitlyHidden
        menu.add(hidden ? "Unhide" : "Hide") { Task { await hide(!hidden) } }
    }
}

// MARK: - The outline view

/// The outline, with the few things the sidebar needs to say to it directly.
final class SidebarOutlineView: NSOutlineView {
    /// True when the key was dealt with and the outline should not see it.
    var onKey: ((NSEvent) -> Bool)?
    var onBecomeFirstResponder: (() -> Void)?
    var onMovedToWindow: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onMovedToWindow?()
        // While the window is being put together the outline passes through
        // the column's widest allowed width before settling at its real one,
        // and a row first drawn in between keeps its selection at that width
        // until it is laid out again. Once the window is there, every row is
        // laid out once more at the width it ended up with.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enumerateAvailableRowViews { row, _ in row.needsLayout = true }
            self.needsLayout = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(row(at: point))
    }

    // A group row's own disclosure control sits on top of the row, in the
    // same trailing corner as a section's add button, and wins the outline's
    // internal hit-testing before it ever reaches our cell. Checking the add
    // button here, ahead of that, is what lets it still be clicked.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarSectionCell {
            let local = cell.convert(point, from: self)
            if cell.performAdd(at: local) { return }
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Cells

/// A native source-list section header with one adjacent creation action.
///
/// AppKit continues to own and operate the disclosure caret. The add button's
/// hit is handled by the cell — and, ahead of AppKit's own group-row hit
/// testing, by `SidebarOutlineView.mouseDown(with:)` — so the button never
/// becomes a separate hover surface that can make AppKit hide its caret.
private final class SidebarSectionCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var onAdd: (() -> Void)?
    private var hasAddAction = false
    private var isHovered = false
    private weak var trackedRow: NSView?
    private var rowTrackingArea: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(name)
        textField = name

        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.imagePosition = .imageOnly
        addButton.imageScaling = .scaleProportionallyDown
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(add)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        if let trackedRow, let rowTrackingArea {
            trackedRow.removeTrackingArea(rowTrackingArea)
        }
        trackedRow = nil
        rowTrackingArea = nil
        isHovered = false

        guard let row = superview else {
            updateAddButtonVisibility()
            return
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        row.addTrackingArea(trackingArea)
        trackedRow = row
        rowTrackingArea = trackingArea
        updateAddButtonVisibility()
    }

    func show(_ section: SidebarSection, onAdd: @escaping () -> Void) {
        name.stringValue = section.title
        self.onAdd = onAdd

        guard let action = section.addAction else {
            hasAddAction = false
            updateAddButtonVisibility()
            return
        }
        hasAddAction = true
        addButton.image = NSImage(systemSymbolName: action.symbol,
                                  accessibilityDescription: action.title)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        addButton.toolTip = action.title
        addButton.setAccessibilityLabel(action.title)
        updateAddButtonVisibility()
    }

    func performAdd(at point: NSPoint) -> Bool {
        guard !addButton.isHidden, addButton.frame.contains(point) else { return false }
        add()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the pointer on the source-list row rather than introducing a
        // second button hover state beside AppKit's disclosure caret.
        if !addButton.isHidden, addButton.frame.contains(point) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if performAdd(at: point) { return }
        super.mouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateAddButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateAddButtonVisibility()
    }

    private func updateAddButtonVisibility() {
        addButton.isHidden = !hasAddAction || !isHovered
    }

    @objc private func add() {
        onAdd?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A row: its icon, its name, the marks of its privacy, and its count.
///
/// The name is the cell's standard `textField`, and the source list owns it:
/// it sets the font for the sidebar icon size chosen in System Settings,
/// weights it for a selection, and recolours it when the selection has the
/// keyboard. The icon is deliberately *not* the cell's `imageView`: the
/// source list sets that outlet's frame itself, at a moment that differs
/// from row to row, and a symbol is drawn to the size of the view it is in
/// — which is how a subfolder's icon came out smaller than its parent's. Kept
/// out of AppKit's hands, the icon sits in a slot of fixed size, drawn at the
/// size `EntityIcon` uses, and takes its colours from the background style
/// by hand.
private final class SidebarRowCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let hiddenBadge = NSImageView()
    private let lockedBadge = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private var isPlaceholder = false
    /// The icon's own colour, if it has one; the accent colour otherwise.
    private var iconTint: NSColor?
    private var iconIsSymbol = false

    /// The size `EntityIcon` draws at, so a folder looks the same here as it
    /// does on the canvas.
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for badge in [hiddenBadge, lockedBadge] {
            badge.imageScaling = .scaleProportionallyDown
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            badge.setAccessibilityElement(false)
        }
        hiddenBadge.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, name, hiddenBadge, lockedBadge, count])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.setCustomSpacing(7, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        textField = name
        recolour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ row: SidebarRow) {
        isPlaceholder = row.isPlaceholder
        name.stringValue = row.title
        hiddenBadge.isHidden = !row.isHidden
        lockedBadge.isHidden = !row.isLocked
        lockedBadge.image = NSImage(
            systemSymbolName: row.isLockOpen ? "lock.open.fill" : "lock.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        if let value = row.count {
            count.stringValue = "\(value)"
            count.isHidden = false
            // Spoken, the trailing number is just a number: "Inbox, 12"
            // could as easily be a name as a tally.
            count.setAccessibilityLabel(Format.itemCount(value))
        } else {
            count.stringValue = ""
            count.isHidden = true
        }

        icon.isHidden = row.icon == nil
        switch row.icon {
        case .symbol(let symbol, let colorHex)?:
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.symbolConfiguration)
            iconTint = NSColor(hex: colorHex)
            iconIsSymbol = true
        case .emoji(let emoji)?:
            icon.image = NSImage.emoji(emoji, pointSize: 15)
            iconTint = nil
            iconIsSymbol = false
        case nil:
            icon.image = nil
            iconIsSymbol = false
        }
        // The icon is decorative: it appears only beside the row's own name.
        icon.setAccessibilityElement(false)
        recolour()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { recolour() }
    }

    override func layout() {
        super.layout()
        // The source list has had its say on the name's font by now; the
        // count keeps pace with it.
        let size = name.font?.pointSize ?? NSFont.systemFontSize
        if count.font?.pointSize != size {
            count.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// The name and the icon are recoloured by the source list. What sits
    /// beside them goes quieter — and, on a selection with the keyboard,
    /// lighter, the way the name does.
    private func recolour() {
        let emphasized = backgroundStyle == .emphasized
        let quiet: NSColor = emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        count.textColor = quiet
        hiddenBadge.contentTintColor = quiet
        lockedBadge.contentTintColor = quiet
        // A symbol takes the accent colour, as sidebar icons do, and goes
        // white on a selection with the keyboard; one given a colour of its
        // own keeps it, the way a coloured tag does in the Finder.
        if iconIsSymbol {
            icon.contentTintColor = emphasized ? .alternateSelectedControlTextColor : (iconTint ?? .controlAccentColor)
        } else {
            icon.contentTintColor = nil
        }
        // "No folders yet" is a note, not a place: it reads quietly and is
        // never selected, so it never needs the selected colour.
        name.textColor = isPlaceholder ? .tertiaryLabelColor : .labelColor
    }
}

// MARK: - Menus and images

private extension NSMenu {
    /// An item that does something, without a target and selector to plumb.
    func add(_ title: String, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, action: action)
        addItem(item)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { closure() }
}

extension NSImage {
    /// An emoji drawn as an icon, so it can sit where a symbol would.
    static func emoji(_ emoji: String, pointSize: CGFloat = 15) -> NSImage {
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        let bounds = text.boundingRect(with: .init(width: 64, height: 64))
        let size = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
        return NSImage(size: size, flipped: false) { rect in
            text.draw(at: NSPoint(x: rect.minX, y: rect.minY))
            return true
        }
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
                  green: CGFloat((number >> 8) & 0xFF) / 255,
                  blue: CGFloat(number & 0xFF) / 255,
                  alpha: 1)
    }
}

extension NSPasteboard.PasteboardType {
    static let nookFolder = NSPasteboard.PasteboardType(UTType.nookFolder.identifier)
    static let nookObject = NSPasteboard.PasteboardType(UTType.nookObject.identifier)
}
#endif
