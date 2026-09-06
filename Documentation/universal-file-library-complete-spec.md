# Universal File Library App
## Complete Working Specification

---

# Universal File Library App
## Working Product Specification

## 1. Product Summary

A native Apple-platform application for storing, organizing, searching, previewing, syncing, and privately managing almost any kind of digital object.

Initial supported object types:

- Images
- Videos
- Audio files
- Screenshots
- PDFs
- Web links
- General files where supported by the platform

Target platforms:

- macOS
- iOS
- iPadOS

Primary implementation goals:

- Native Swift
- SwiftUI where appropriate
- Apple-native frameworks wherever practical
- Minimal third-party dependencies
- Small external packages/extensions are acceptable where they avoid rebuilding genuinely complex infrastructure

The app should behave as a managed personal library, not as a filesystem browser and not as a file editor.

---

# 2. Core Terminology

## Object

The universal term for anything stored in the library.

An object may represent:

- Image
- Video
- Audio file
- PDF
- Screenshot
- Web link
- Other supported file type
- Future object types

All object types share a common base model and can coexist in folders, search results, collections, favorites, and other global views.

Type-specific behavior is layered on top of the universal object model.

---

## Folder

A folder is part of the true organizational hierarchy.

Folders may contain:

- Objects
- Other folders

Folder nesting is unlimited.

Every object has exactly one location in the folder hierarchy, or exists at the library root.

---

## Collection

A collection is a manual aggregation of objects from anywhere in the library.

Collections:

- Do not contain folders
- Do not own objects
- Do not affect an object's true folder location
- Can contain objects from many different folders
- Can preserve custom manual ordering
- Can also be sorted using normal sort modes

An object may belong to multiple collections simultaneously.

---

## Smart Collection

A Smart Collection is an automatically populated collection based on saved rules.

Smart Collections:

- Aggregate objects from anywhere in the library
- Do not change object locations
- Store filter rules
- Store a default sort order
- Update automatically as objects and metadata change

---

# 3. Managed Library

The app owns imported content.

When a file is imported:

1. The app creates a managed object.
2. The app stores its own copy of the underlying file data.
3. The object no longer depends on the original filesystem location.
4. Moving or deleting the original external file does not affect the library object.

The app is therefore closer to Photos than Finder.

---

# 4. Storage and Blob Model

Objects and underlying file data are separate concepts.

An object contains:

- Identity
- Metadata
- Folder location
- Tags
- Collection relationships
- Privacy state
- Other object-level properties

The underlying immutable binary file is stored as a reusable blob.

## Shared Blob Storage

Multiple objects may reference the same underlying blob.

Example:

A 500 MB video is duplicated into another folder.

Result:

- Two independent objects exist
- Each object has its own metadata and folder location
- Both may initially reference the same underlying 500 MB blob
- Storage is not unnecessarily duplicated

Because stored object contents are immutable, shared blob storage is safe and predictable.

---

# 5. Copies

Users may intentionally create multiple copies of the same file.

Each copy becomes an independent object.

Copied objects may independently have:

- Different names
- Different titles
- Different descriptions
- Different tags
- Different folder locations
- Different collection memberships
- Different hidden states
- Different locked states
- Different favorite states

The underlying binary blob may remain shared.

---

# 6. No Aliases

The app does not support filesystem-style aliases or shortcuts.

If an object needs to appear in another context:

- Use a Collection, or
- Create another copy

This avoids introducing another reference model.

---

# 7. No Versioning

Objects are immutable.

Replacing a file is not treated as a new version of the same object.

A revised file becomes a new object.

There is no automatic or manual version history in the core model.

---

# 8. Folder Hierarchy

The true storage hierarchy is:

```text
Library Root
├── Folder
│   ├── Object
│   ├── Object
│   └── Subfolder
│       └── Object
│
├── Folder
│   └── Object
│
└── Loose Object
```

Folders:

- Can contain objects
- Can contain subfolders
- Can be nested without an artificial depth limit
- Appear in the sidebar when located at the library root

Objects cannot exist in multiple folders simultaneously.

Moving an object changes its true location.

---

# 9. Inbox / Unsorted

Inbox is not a normal user-created folder.

Instead, it is a system view of root-level objects.

A root-level object is considered:

**Inbox / Unsorted**

Root-level folders are not shown in Inbox.

They appear normally in the sidebar.

Objects may remain in Inbox indefinitely.

The app does not force users to organize them into folders.

Conceptually:

```text
Library Root
├── Folder
├── Folder
├── Object ← appears in Inbox
├── Object ← appears in Inbox
└── Object ← appears in Inbox
```

Inbox cannot be:

- Renamed
- Deleted
- Duplicated
- Recreated by the user

---

# 10. Collections

Collections appear in a dedicated sidebar section separate from folders.

Collections are flat.

They cannot:

- Contain other collections
- Be nested
- Be grouped into collection folders

Manual collections can contain any number of object references.

Objects remain physically located in their folders.

---

# 11. Manual Collection Ordering

Manual Collections support:

- Custom drag-and-drop ordering
- Standard sort modes

Examples of standard sorting:

- Name
- Date added
- Date created
- File type
- Size
- Modification metadata where relevant

Manual ordering is collection-specific and does not affect object ordering elsewhere.

---

# 12. Smart Collections

Smart Collections automatically aggregate matching objects.

Possible rules include:

- Tag equals `reference`
- Type equals `PDF`
- Type equals `image`
- Favorite equals true
- Date added within last 30 days
- Source domain equals `are.na`
- Folder equals X
- File size above/below threshold
- Other metadata conditions

Each Smart Collection stores:

- Filter rules
- Default sort order

Manual and Smart Collections remain distinct concepts.

Smart Collections do not support manually added exceptions in the core design.

---

# 13. Tags

Tags use a flat structure.

Examples:

- reference
- inspiration
- typography
- client
- music
- research

Tags do not nest.

More complex organization is handled through:

- Multiple tags
- Smart Collections
- Filters
- Search

---

# 14. Universal Object Model

All stored content uses the same underlying object architecture.

Examples:

- Image object
- Video object
- Audio object
- PDF object
- Link object
- Generic file object

The app may expose filtered global views such as:

- All Objects
- Images
- Videos
- Audio
- PDFs
- Links
- Screenshots
- Favorites
- Recent

These are views over the same library, not separate storage areas.

---

# 15. Object Metadata

Every object supports rich editable metadata.

Common metadata may include:

- Title
- Original filename
- Description
- Notes
- Tags
- Favorite state
- Date added
- Original creation date
- Source URL
- File type
- MIME / UTI information
- File size
- Dimensions
- Duration
- Folder location
- Collection membership
- Custom thumbnail or cover
- Type-specific metadata

The underlying stored file remains immutable.

---

# 16. Web Links

Web links are objects.

A link object stores rich metadata where available:

- URL
- Page title
- Description
- Preview image
- Favicon
- Domain
- Open Graph metadata
- Other relevant page metadata

The webpage itself is not archived.

The live webpage remains the destination.

Opening a web link opens it externally, normally in Safari or the user's configured browser.

---

# 17. Internal Preview Behavior

The app previews supported stored media internally.

Internal previews include:

- Images
- Video
- Audio
- PDFs

Web links open externally by default.

The app is a library and organizer, not an editor.

---

# 18. File Immutability

Imported file contents cannot be modified inside the app.

The app does not provide:

- Image editing
- Video editing
- Audio editing
- PDF editing
- File-content replacement

Users may modify:

- Metadata
- Tags
- Folder location
- Collection membership
- Favorite state
- Hidden state
- Locked state

A modified external revision is imported as a new object.

---

# 19. Import Paths

The app should support all major native import routes.

## macOS

- Drag and drop
- File picker
- Paste
- Clipboard capture
- Share menu / Share Extension where available

## iOS / iPadOS

- Files picker
- Photos picker
- Paste
- Clipboard capture
- Share Extension

The Share Extension is a core product feature.

---

# 20. Import Destination Behavior

Imports are context-aware.

If the user imports while viewing a folder:

- The object is imported into that folder.

If the user imports without a folder context:

- The object is created at the library root.
- It therefore appears in Inbox / Unsorted.

The Share Extension should allow explicit destination selection where appropriate.

---

# 21. Duplicate Detection

If an identical file has already been imported, the app warns the user.

The user can choose to:

- Use the existing object
- Create another independent object

The app should not silently remove duplicates or silently create copies without informing the user.

Duplicate detection may use content hashing.

---

# 22. iCloud Sync

The library is iCloud-backed.

The app syncs:

- Object records
- Metadata
- Folder hierarchy
- Collection membership
- Smart Collection definitions
- Tags
- Privacy state
- Blob references
- Stored files
- Other durable library state

The app is Apple-platform-only, so iCloud is the primary sync solution.

---

# 23. On-Demand File Availability

Original file content does not need to exist locally on every device.

Default behavior:

- Metadata syncs
- Thumbnails/previews sync or regenerate
- Original file blobs download on demand

Example:

A 2 GB video imported on Mac may appear immediately on iPhone through metadata and preview information without downloading the full 2 GB file.

The full file downloads when required.

---

# 24. Keep Locally

Objects, folders, and collections may be marked:

**Keep Locally**

This setting is per device.

## Object

The object's underlying file is downloaded and retained locally.

## Folder

All objects under the folder hierarchy are downloaded and retained locally.

This is a persistent rule.

New objects added anywhere beneath the folder later are also automatically kept locally.

## Collection

All objects currently referenced by the collection are retained locally.

The rule persists.

Objects added to the collection later are also automatically retained locally.

The feature affects local availability only.

It does not alter cloud storage or hierarchy.

---

# 25. Hidden State

Any of the following may be explicitly hidden:

- Object
- Folder
- Collection
- Smart Collection

Authentication is required to:

- Hide
- Unhide

Authentication should use native system authentication:

- Face ID
- Touch ID
- Device authentication fallback where appropriate

---

# 26. Hidden Objects

An explicitly hidden object is hidden globally.

It should not appear in:

- Normal folders
- Collections
- Smart Collections
- Search
- Recent
- Favorites
- Spotlight
- Siri suggestions
- Widgets
- Other normal discovery surfaces

The object's hidden state follows the object regardless of where it is referenced.

---

# 27. Hidden Folders

Hidden state follows the true folder hierarchy.

If a folder is hidden:

- Its descendant folders are effectively hidden
- Its descendant objects are effectively hidden
- Those objects are also hidden when referenced by Collections or Smart Collections

The inherited state does not need to permanently modify every child object's explicit hidden flag.

Conceptually:

```text
Hidden Folder
└── Subfolder
    └── Object
```

The object is effectively hidden everywhere because its true location is under a hidden ancestor.

---

# 28. Hidden Collections

A hidden Collection or Smart Collection hides only that collection surface.

It does not hide its underlying objects.

Example:

```text
Hidden Collection
├── Object A
└── Object B
```

The Collection is concealed.

Object A and Object B remain visible in their actual folders unless they or their ancestor folders are hidden.

This creates a distinction between:

- Storage-hierarchy privacy
- Collection-surface privacy

---

# 29. Share Extension and Hidden Destinations

Hidden folders and collections may still be used as destinations through the Share Extension.

This allows users to save content directly into private organizational areas without first making them visible.

Appropriate authentication should be required before revealing or selecting protected destinations where necessary.

---

# 30. Locked State

Any of the following may be explicitly locked:

- Object
- Folder
- Collection
- Smart Collection

Authentication is required to:

- Open locked content
- Lock
- Unlock

Authentication uses native system authentication.

---

# 31. Locked Objects

An explicitly locked object requires authentication everywhere.

If a locked object appears:

- In its folder
- In a Collection
- In a Smart Collection
- In search
- In another permitted surface

its content remains protected until authentication.

The object may still surface structurally where appropriate, but its preview/content must not be exposed.

---

# 32. Locked Folders

Lock state follows the true folder hierarchy.

If a folder is locked:

- Opening that folder requires authentication
- Descendant folders inherit effective protection
- Descendant objects inherit effective protection
- Those objects remain protected even when surfaced through Collections or Smart Collections

The folder hierarchy is authoritative for inherited security.

---

# 33. Locked Collections

A locked Collection or Smart Collection protects only access through that collection.

It does not change underlying object security.

Example:

```text
Locked Collection
└── Object A

Normal Folder
└── Object A
```

Opening the Collection requires authentication.

Object A remains normally accessible through its folder unless:

- Object A itself is locked, or
- An ancestor folder is locked

Collection-level security is therefore path-specific.

---

# 34. Hidden and Locked Are Independent

An object, folder, collection, or Smart Collection may be:

- Normal
- Hidden
- Locked
- Hidden + Locked

These states solve different problems.

**Hidden** controls discoverability.

**Locked** controls authenticated access.

---

# 35. System Discovery Behavior

## Hidden Content

Hidden content is excluded from:

- Spotlight
- Siri suggestions
- Widgets
- Recents
- Global search
- Other discovery surfaces

## Locked Content

Locked folders or collections may surface structurally.

However:

- Protected contents
- Thumbnails
- Previews
- Sensitive metadata

must not be exposed without authentication.

---

# 36. Search

Search should cover both metadata and content.

Searchable metadata includes:

- Title
- Filename
- Description
- Notes
- Tags
- Folder
- Collection relationships
- Dates
- Source URL
- Domain
- File type
- Other structured metadata

---

# 37. Document Text Search

Where supported, the app extracts and indexes text from documents.

Examples:

- PDFs
- Text-bearing files
- Other supported document formats

Extracted text becomes searchable without modifying the underlying file.

---

# 38. OCR

Images and screenshots should support OCR indexing.

Detected text becomes searchable.

OCR output is treated as derived data.

The original image remains unchanged.

---

# 39. Web Search Metadata

Link objects are searchable through stored metadata such as:

- Title
- URL
- Domain
- Description
- Open Graph data

The app does not need to crawl and archive entire webpages.

---

# 40. Search Index Architecture

Search uses a hybrid model.

## Durable Synced Data

Core searchable metadata may sync through iCloud.

## Derived Local Data

Heavier generated data can be recreated locally.

Examples:

- OCR caches
- Local indexes
- Derived thumbnails
- Temporary analysis data

These caches are not treated as irreplaceable user data.

---

# 41. Search Privacy

Search must respect effective privacy state.

Objects are excluded or protected based on:

- Explicit object hidden/locked state
- Hidden/locked folder ancestry
- Current authentication state
- Collection-level access rules when browsing through a collection

The folder hierarchy is authoritative for inherited object privacy.

---

# 42. Home

The Home screen is customizable.

Possible sections include:

- Inbox
- Recent
- Favorites
- Specific folders
- Specific collections
- Smart Collections
- Type-based views

Default Home layout:

- Inbox
- Recent

The goal is a useful workspace rather than a dashboard-heavy landing page.

---

# 43. Sidebar

The sidebar should conceptually separate:

## System

- Home
- Inbox
- Recent
- Favorites
- All Objects
- Recently Deleted

## Folders

Root-level folders and their nested hierarchy.

## Collections

Flat list of:

- Manual Collections
- Smart Collections

The exact visual grouping remains open for design exploration.

---

# 44. Deletion

Removing an object from a Collection is not deletion.

## Remove From Collection

This removes only the collection membership.

The object:

- Remains in its folder
- Remains in other collections
- Remains in the library

## Delete Object

Deleting an object removes it from its true location and sends it to Recently Deleted.

---

# 45. Recently Deleted

Deleted objects are recoverable.

Retention is configurable.

Initial options:

- 30 days
- 60 days
- 90 days
- Until manually deleted

Default:

**30 days**

Users may manually empty Recently Deleted.

Permanent deletion should clean up any now-unreferenced underlying blob data.

---

# 46. Blob Garbage Collection

Because multiple objects may share one underlying blob:

Deleting one object must not delete the blob if another object still references it.

The underlying file blob can be permanently removed only when:

- No live object references it
- No Recently Deleted object references it
- No other durable system state requires it

---

# 47. Core Structural Model

The current model can be summarized as:

```text
Library
│
├── Root Objects
│   └── surfaced as Inbox / Unsorted
│
├── Folder Hierarchy
│   ├── Folder
│   │   ├── Object
│   │   └── Folder
│   │       └── Object
│   └── Folder
│       └── Object
│
├── Collections
│   ├── Manual Collection
│   │   └── references Objects
│   └── Smart Collection
│       └── queries Objects
│
├── Global Views
│   ├── All Objects
│   ├── Recent
│   ├── Favorites
│   ├── Images
│   ├── Videos
│   ├── PDFs
│   ├── Audio
│   └── Links
│
└── Recently Deleted
```

---

# 48. Privacy Model Summary

The privacy model has two layers.

## True Hierarchy Privacy

Applies to:

- Objects
- Folders

Folder privacy inherits downward.

This affects objects everywhere they appear.

## Collection Surface Privacy

Applies to:

- Manual Collections
- Smart Collections

This protects or hides access through that collection only.

It does not mutate underlying object privacy.

---

# 49. Product Principles

## Native First

The app should feel like a real macOS/iOS application, not a web application inside a native shell.

## Universal Objects

Different media types share one coherent library.

## True Hierarchy + Flexible Aggregation

Folders define real object location.

Collections provide cross-folder organization without compromising the hierarchy.

## Managed Storage

The app owns its imported content.

## Immutable Files

The app preserves stored files rather than becoming a media editor.

## Metadata Is First-Class

Rich metadata is editable independently of the file.

## Privacy Is Architectural

Hidden and locked behavior must be designed into:

- Hierarchy
- Collections
- Search
- Previews
- Share Extension
- Spotlight
- Sync
- Caching

from the beginning.

## Cloud Without Forced Local Storage

iCloud provides synchronization while large files remain on demand.

## Recoverability

Deletion is reversible for a configurable period.

## Minimal Model Complexity

Avoid:

- Aliases
- Versioning
- Multiple-folder object ownership
- Nested collections
- Mixed manual + rule-based Smart Collections

unless a future use case clearly justifies them.

---

# Universal File Library App
## UX/UI Specification

## 1. Overall UX Direction

The application should behave more like **Apple Photos** than Finder.

Core experience:

- Visual browsing first
- Native platform behavior
- Large content canvas
- Minimal persistent chrome
- Content opens directly in the main window
- Metadata and secondary controls stay out of the way until requested
- Folder hierarchy and collections remain visible without turning the app into a traditional file manager

## 2. Primary Window Structure

### macOS

- Sidebar
- Main content canvas
- Toolbar

No persistent inspector by default.

Opening an object replaces the browsing canvas with the object preview, similar to Apple Photos.

Returning to the previous view should preserve scroll position, selection, and view state where practical.

## 3. Platform-Native Interaction

### macOS

Use native pointer, keyboard, selection, context-menu, drag-and-drop, and navigation behavior.

### iOS / iPadOS

Use native touch behavior:

- Tap to open
- Native multi-selection
- Context menus
- Drag-and-drop on iPadOS
- Standard gestures
- Platform-native sheets and navigation

## 4. Browsing Modes

Supported views:

- **List**: dense, metadata-oriented browsing
- **Icon Grid**: Finder-like regular grid
- **Masonry Grid**: variable-height visual layout

## 5. Global vs Per-Location View Settings

The app has global defaults.

A folder or collection can temporarily override them.

An explicit **Remember for this folder / collection** control persists the current local preference.

## 6. Sort Behavior

Global default sort plus temporary and remembered local overrides.

Potential sorts:

- Name
- Date added
- Date created
- Type
- Size
- Duration
- Other relevant metadata

## 7. Grouping

Grouping follows the same system.

Possible grouping:

- None
- Type
- Date
- Tag
- Folder
- Other metadata-derived groups

## 8. Card Density

Grid and Masonry views support:

- Minimal
- Standard
- Detailed

Standard is default.

## 9. Folder Presentation in the Main Canvas

Two independent settings:

### Folders First

Folders appear before objects.

### Group Folders

Folders appear in a dedicated folder section separate from objects.

Both settings support global defaults, temporary overrides, and explicit remembered overrides per folder.

## 10. Preview Experience

Object preview is content-first.

When an object is opened:

- It occupies the main canvas
- Preview content is as large as practical
- Chrome remains minimal
- Only essential controls remain visible
- Metadata is not permanently exposed

Images, video, audio, and PDFs preview internally.

Web links open externally by default.

## 11. Info / Metadata Interface

Metadata remains hidden until explicitly requested.

### macOS / iPadOS

Right-side information panel.

### iPhone

Bottom sheet or full-height sheet.

## 12. Sidebar

The sidebar is a major navigation surface on macOS and iPadOS and is user-customizable.

### System

- Home
- Inbox
- Recent
- Favorites
- All Objects
- Recently Deleted

### Folders

- Root-level folders appear in the sidebar
- Nested folders can expand inline with disclosure controls
- Nested folders can also be navigated in the main canvas
- Objects never appear in the sidebar

### Collections

- Manual Collections
- Smart Collections
- Flat list, no nesting

### Media Types

- Images
- Videos
- Audio
- PDFs
- Links
- Screenshots

Selecting one shows all matching objects across the library, subject to privacy rules.

### Tags

All tags appear directly in the sidebar.

Selecting a tag shows all matching objects across the library.

## 13. Sidebar Customization

Users can customize sidebar contents.

Sidebar sections should be independently collapsible.

## 14. Home

Home is a customizable section-based view.

Users can add, remove, and reorder sections.

Sections may point to:

- Folders
- Collections
- Smart Collections
- Tags
- Media Types
- Inbox
- Recent
- Favorites
- Other system views

Default Home:

- Inbox
- Recent

## 15. Toolbar

The toolbar is adaptive.

### Browsing Context

Likely controls:

- Navigation
- Search
- Add / Import
- View mode
- Sort
- Grouping
- Filtering

### Object Preview Context

Preview controls may include:

- Back
- Info
- Share
- Favorite
- More actions
- Type-specific playback / preview actions

## 16. Search Overview

Two search concepts:

1. Contextual / scoped search
2. Global search

## 17. Scoped Search

Searching while inside a browsing context automatically scopes search to that location.

The active scope appears visibly in the search field as a removable pill.

Removing the pill expands the same query to the full library.

Scoped search applies to:

- Folders
- Collections
- Smart Collections
- Tags
- Media Types

Default shortcut: **Command-F**.

## 18. Search UI by Platform

### macOS / iPadOS

Persistent toolbar search field.

### iPhone

Native integrated search presentation.

## 19. Global Search

Global Search is available anywhere.

Default shortcut: **Command-Shift-F**.

Shortcuts are user-customizable.

Global Search opens as a floating command-palette-style overlay containing:

- Search field
- Search results
- Lightweight filters

Global Search begins unscoped.

## 20. Global Search Filters

Initial filters:

- Media type
- Tag
- Folder
- Date
- Favorite
- Locked state where permitted
- Hidden state where authenticated/permitted
- Source or domain where relevant

## 21. Browser Filtering

Browsing surfaces support filtering independent of text search.

Examples:

- Type
- Tag
- Date
- Favorite
- Folder
- Source

Any useful filter configuration can be converted into a Smart Collection.

## 22. Customization

The app should support substantial user-controlled personalization.

### Folder customization

Folders can have:

- Custom color
- Custom SF Symbol / icon
- Emoji

### Collection customization

Collections and Smart Collections can have:

- Custom color
- Custom SF Symbol / icon
- Emoji

### Tag customization

Tags can have:

- Custom color
- Custom SF Symbol / icon
- Emoji

No custom image covers.

### App appearance

Users can customize:

- Global app tint / accent color
- Light / dark / system appearance

Folder, Collection, and Tag colors remain identity markers rather than changing the entire UI context.

## 23. Interaction Principles

- Content first
- Native behavior
- Context is visible
- Global defaults, explicit exceptions
- Visual browsing + utility
- No permanent inspector clutter
- Folder hierarchy without Finder UX
- Flexible search

---

# Universal File Library App
## MVP Product + UX/UI Scope

## 1. MVP Goal

Build a native macOS, iOS, and iPadOS application that lets a user:

1. Import almost any common file or web link
2. Store it inside a managed iCloud-backed library
3. Organize it into folders, tags, and collections
4. Browse it visually or as a list
5. Search for it
6. Preview it
7. Access the same library across Apple devices

The MVP should validate the core library model before adding deeper automation, privacy systems, advanced indexing, or extensive customization.

## 2. Priority Labels

### MVP

Required for the first usable product.

### MVP Architecture

Underlying model should support it now even if the UI is later.

### Post-MVP

Important features that should follow soon.

### Later

Useful enhancements that should not influence initial implementation significantly.

## 3. MVP Features

### Platforms

- macOS
- iOS
- iPadOS
- Native Swift
- SwiftUI where appropriate
- Apple-native frameworks wherever practical

### Universal Object Model

Initial supported object types:

- Images
- Video
- Audio
- PDFs
- Screenshots
- Web links
- Generic files

Every Object has:

- Stable ID
- Title
- Original filename where applicable
- Type
- Date added
- File size where applicable
- Folder location
- Favorite state
- Tags
- Collection relationships
- Blob reference where applicable

### Managed Library

Imported files are copied into the application's managed library.

### Immutable File Content

Stored file contents cannot be edited inside the app.

### Folder Hierarchy

Folders can contain Objects and other folders.

Every Object exists in exactly one Folder or the library root.

### Inbox / Unsorted

Root-level Objects appear in Inbox.

Inbox is a system view, not a user-editable Folder.

### Collections

Manual Collections aggregate Objects from across the folder hierarchy.

### Tags

Objects can have multiple flat Tags.

### Favorites

Objects can be marked as Favorite.

### Main Navigation

#### macOS / iPadOS

- Sidebar
- Main content canvas
- Toolbar

Sidebar sections:

- System
- Folders
- Collections
- Media Types
- Tags

### Home

Simple entry screen.

Default:

- Inbox
- Recent

### Browsing Modes

- List
- Icon Grid
- Masonry Grid

### View Preferences

Global default View Mode with optional explicit **Remember for this folder / collection**.

### Sorting

Initial sorting:

- Name
- Date Added
- Date Created
- Type
- Size

### Folder Display

Folders First in the initial build.

### Object Preview

Internal preview for:

- Images
- Video
- Audio
- PDFs
- Generic files where supported

Web links open externally.

### Preview Navigation

Users can move between adjacent Objects without returning to the grid.

### Info / Metadata

Editable:

- Title
- Notes / description
- Tags
- Favorite
- Folder
- Collection membership

Read-only:

- Filename
- Type
- Size
- Date added
- Dimensions
- Duration
- Source URL

### Import

#### macOS

- Drag and drop
- File picker
- Paste files
- Paste URLs

#### iOS / iPadOS

- Files picker
- Photos picker
- Paste
- Share Extension

### Import Destination

Context-aware.

If importing while viewing a Folder, import there.

Otherwise import at Library Root and show in Inbox.

### Import Progress

Visible progress for large files.

Failed imports have retry/error state.

### Search

Metadata search across:

- Title
- Filename
- Notes
- Tags
- Folder
- Collection
- Media type
- URL/domain

### Scoped Search

Current context appears as removable pill.

Default shortcut: **Command-F**.

### Global Search

Floating command-palette-style overlay.

Default shortcut: **Command-Shift-F**.

Initial palette includes:

- Search field
- Immediate results
- Basic type filter

### Web Links

Store:

- URL
- Page title
- Domain
- Preview image where available
- Favicon where available
- Description / Open Graph metadata where available

### iCloud Sync

Sync:

- Objects
- Metadata
- Folder hierarchy
- Tags
- Collections
- Favorites
- Stored files
- Blob relationships

### Recently Deleted

Default retention: **30 days**.

Restore and permanently delete supported.

### Remove From Collection

Removing Collection membership does not delete the Object.

### Customization

Folders, Collections, and Tags support:

- Color
- SF Symbol / icon
- Emoji

No custom covers.

### App Tint

User-selectable global app tint / accent color.

### Appearance

- Light
- Dark
- System

### Keyboard Shortcuts

Core native shortcuts for:

- Search current context
- Global Search
- Import
- New Folder
- New Collection
- Delete
- Info
- Favorite
- Back / forward
- View switching

### Drag and Drop

Support:

- Importing external files
- Moving Objects between folders
- Adding Objects to Collections
- Moving folders

### Selection and Batch Actions

- Move
- Add to Collection
- Add / remove Tags
- Favorite / unfavorite
- Delete
- Share / export

### Export / Sharing

- Export original files
- Drag files back into Finder
- System Share Sheet
- Share multiple selected Objects

### Loading and Error States

Explicit states for:

- Importing
- Uploading
- Downloading
- Offline
- Failed import
- Failed sync
- Missing local Original
- Empty Folder
- Empty Collection
- Empty Inbox
- Empty search result

## 4. MVP Architecture

Must be designed into the schema now:

- Shared immutable blobs
- Stable Object IDs
- Stable Folder IDs
- iCloud synchronization identifiers
- Hidden state
- Locked state
- Folder privacy inheritance
- Collection privacy independence
- Smart Collection rules
- Per-device Keep Locally state
- Derived searchable text
- Per-location view preferences

## 5. Post-MVP

- Smart Collections
- Sidebar customization
- User-customizable Home
- Grouping
- Group Folders
- Card density
- Duplicate detection UX
- Object copies
- Global Search advanced filters
- Browser filtering
- Save filter as Smart Collection
- OCR
- Full-content search
- Keep Locally controls
- Hidden UI
- Locked UI
- Configurable Recently Deleted retention
- User-customizable keyboard shortcuts

## 6. Later

- AI tagging
- Semantic search
- Automatic categorization
- Object recognition
- Natural-language Smart Collections
- Duplicate similarity detection
- Automatic organization
- System privacy integrations
- Collaboration
- Public cloud-sharing links
- Rich editing
- Version history
- Aliases
- Plugin system
- Custom themes

## 7. Recommended Build Order

### Phase 1: Local Core

1. Universal Object model
2. Blob/file storage
3. Folder hierarchy
4. Inbox
5. Import
6. Basic metadata
7. Grid
8. Object preview
9. Move/delete
10. Persistence

### Phase 2: Organization

1. Collections
2. Tags
3. Favorites
4. Media Type views
5. List view
6. Masonry view
7. Sort
8. Folder customization
9. Collection customization
10. Tag customization

### Phase 3: Retrieval

1. Metadata search
2. Scoped Search
3. Global Search palette
4. Multi-select
5. Export
6. Share
7. Drag-and-drop refinement

### Phase 4: Apple Ecosystem

1. iCloud synchronization
2. iOS/iPadOS shared library
3. Share Extension
4. On-demand file downloads
5. Offline synchronization behavior

### Phase 5: MVP Polish

1. Home
2. Recently Deleted
3. App tint
4. Empty states
5. Error handling
6. Import/download progress
7. Keyboard shortcuts
8. Per-location remembered view settings
9. Performance work
10. Accessibility and native interaction polish

## 8. MVP Product Definition

> A fast, native, visual personal file library for Apple devices where any file or link can be saved, organized into real folders plus flexible Collections and Tags, found quickly, previewed beautifully, and retrieved intact.

---

# Universal File Library App
## AI & External Intelligence Architecture

## 1. Core Principle

The library should be usable by:

- Humans through the native UI
- Software agents through a structured access layer

The UI must not be the only way to interact with library content.

This capability is part of the MVP architecture even though conversational AI features themselves are not required for the first usable build.

## 2. Internal Library Access Layer

Create a Swift-native service layer between the application's database/storage and all consumers.

Conceptually:

```text
                  Native UI
                     │
              ┌──────▼──────┐
              │ Library Core │
              │  Access API  │
              └──────┬──────┘
                     │
        ┌────────────┼─────────────┐
        │            │             │
        ▼            ▼             ▼
    App Intents     MCP        Foundation
    / Siri         Adapter       Models
        │            │             │
        ▼            ▼             ▼
      Siri       Claude /       In-App
     System      ChatGPT        Local AI
```

Every integration accesses the same underlying capabilities.

Do not implement separate querying logic for Search UI, Siri, MCP, Local AI, or future integrations.

## 3. Initial Library Capabilities

### Navigation

- List root folders
- List folder contents
- List collections
- List tags
- List media types

### Object Retrieval

- Get Object by stable ID
- Get Object metadata
- Get Object location
- Get Object tags
- Get Object collection memberships
- Get Object type

### Search

- Search Objects
- Search within Folder
- Search within Collection
- Search by Tag
- Search by media type

### Content

Where available:

- Return extracted text
- Return link metadata
- Return thumbnail / preview representation
- Provide controlled access to the Original

## 4. Read-Only First

External intelligence access should initially be **read-only**.

Allow:

- Search
- Find
- Inspect
- Retrieve
- Summarize
- Reason over content

Do not initially allow an external LLM to:

- Delete Objects
- Move Objects
- Hide Objects
- Unlock Objects
- Modify metadata
- Create folders
- Create Collections

## 5. Future Write Actions

Post-MVP:

- Add Tag
- Remove Tag
- Favorite
- Create Collection
- Add Object to Collection
- Move Object
- Rename Object
- Create Folder

Destructive or privacy-sensitive operations should require explicit user confirmation.

## 6. Privacy Broker

Every consumer must pass through the same privacy layer.

The LLM integration must never bypass normal privacy semantics.

### Hidden

Hidden content is not returned through:

- Search
- MCP
- Siri
- Spotlight
- Local AI
- External AI

unless the user has explicitly entered an authenticated Hidden context.

### Locked

Locked content cannot have its contents exposed until authentication requirements have been satisfied.

The privacy layer operates below the LLM/tool layer.

## 7. Stable Machine Identity

Objects, Folders, Collections, Tags and other significant entities should have durable identifiers.

They must not depend on:

- Filename
- Path
- Display title
- Sort position

Example:

```text
object://7C42...
folder://98AF...
collection://62D1...
tag://194E...
```

## 8. App Intents / Siri

Expose useful library entities and actions using Apple's App Intents and App Entities frameworks.

Initial intents should include:

- Search Library
- Find Objects
- Open Object
- Open Folder
- Open Collection
- Show Objects with Tag
- Show Media Type

This makes the library accessible to:

- Siri
- Apple Intelligence
- Spotlight
- Shortcuts
- Other system integrations

## 9. Siri Example Use Cases

- Show me PDFs I saved about Japanese architecture.
- Find my references tagged typography.
- Open my Tokyo collection.
- Show me images I saved last week.
- Find the PDF from Sony.

## 10. MCP Adapter

The internal access layer should be straightforward to expose as MCP tools/resources.

Do not make MCP types part of the core data model.

```text
MCP request
    ↓
MCP Adapter
    ↓
Library Access API
    ↓
Library
```

## 11. Initial MCP Tool Surface

A first read-only MCP interface could expose:

```text
search_objects
get_object
get_object_content
list_folder
list_collections
get_collection
list_tags
find_by_tag
```

Potential queries:

- Find everything I've saved about brutalist architecture.
- Give me the PDFs related to Client X.
- What references have I stored from are.na?
- Look through my research folder and summarize the relevant documents.
- Find images that might work as visual references for this presentation.

## 12. Local MCP on Mac

The macOS app can potentially expose a local MCP bridge.

Advantages:

- Library data does not need to leave the computer except when deliberately passed to the chosen model
- No separate account system
- No server-side copy of the user's library
- Useful for desktop agents and developer/agent tools

This should be the first MCP implementation.

## 13. Remote MCP

Later.

Potentially requires:

- Backend infrastructure
- Authentication
- OAuth
- Remote authorization
- Secure API endpoints
- User identity
- Access revocation
- Rate limiting
- Potential server-side indexing or forwarding

Remote MCP should not be required for MVP.

## 14. In-App On-Device Intelligence

Post-MVP, architecture now.

Potential capabilities:

- Ask questions about selected Objects
- Summarize PDFs
- Extract useful metadata
- Describe images
- Suggest Tags
- Find related Objects
- Search conversationally
- Compare Objects
- Create temporary result sets from natural language

## 15. Model Abstraction

Do not make any single provider the permanent intelligence interface.

```text
IntelligenceSession
        │
        ├── Apple Foundation Model
        ├── Claude
        ├── OpenAI
        └── Future provider
```

## 16. Local AI UX

Do not make the application fundamentally chat-based.

AI should appear where useful.

Examples:

- Global Search: natural-language query
- Selection: select PDFs and summarize
- Folder: ask about this folder
- Collection: find related items
- Tagging: suggest Tags
- Inspector: describe / summarize

## 17. Content Representations

Every Object should be capable of providing machine-readable representations.

### Image

- Metadata
- Thumbnail
- Original
- OCR text eventually
- Vision-compatible representation

### PDF

- Metadata
- Extracted text
- Page structure where available
- Original

### Web Link

- URL
- Title
- Description
- Domain
- Preview image
- Open Graph metadata

### Audio / Video

- Metadata
- Duration
- Original
- Transcript eventually

### Generic document

- Metadata
- Extracted text where possible
- Original

## 18. PDF Text Extraction

Move basic text extraction earlier in the roadmap because it is valuable to Search, Siri, MCP, Local AI, and future semantic search.

## 19. OCR

Post-MVP.

Derived-data model should already support storing/rebuilding:

- OCR text
- Transcripts
- AI descriptions
- Embeddings
- Other derived representations

## 20. Derived Content Architecture

Separate user-owned metadata from machine-derived metadata.

```text
Object
├── User Metadata
│   ├── Title
│   ├── Notes
│   └── Tags
│
├── File Metadata
│   ├── Type
│   ├── Dimensions
│   └── Duration
│
└── Derived Metadata
    ├── Extracted Text
    ├── OCR
    ├── Transcript
    ├── AI Description
    └── Embeddings
```

Derived metadata can be regenerated, deleted, device-local, or synced selectively without changing the actual Object.

## 21. Revised MVP Intelligence Scope

### Ship in MVP

- Clean Library Access API
- Stable machine-readable IDs
- Privacy broker
- Metadata search API
- Basic PDF/text extraction infrastructure
- App Intents
- App Entities
- Siri / Shortcuts / Spotlight-compatible library entities
- Model-provider abstraction
- Derived-metadata storage model

### Experimental During MVP Development

- Read-only local MCP bridge on macOS
- Basic on-device model experiments
- Natural-language library querying

### Post-MVP

- In-app local AI features
- AI tagging
- Summarization
- OCR
- Image understanding
- Semantic search
- MCP UI/configuration
- External write actions
- Claude/OpenAI direct providers

### Later

- Remote MCP gateway
- Cloud-agent access while devices are offline
- Automated agent workflows
- Background AI organization
- Cross-library autonomous operations

## 22. Product Principle

The MVP should not be:

> A file manager with an AI chat box.

It should be:

> A structured personal content library whose contents are natively understandable and addressable by both the user and intelligent software.

The native interface remains the primary product.

AI is another interface to the same library.
