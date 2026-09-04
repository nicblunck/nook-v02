# Nook

A native personal library for macOS, iOS and iPadOS: import almost any file or
link, organise it with real folders plus flexible collections and tags, browse
it visually, and get the original back intact.

## Getting started

The Xcode project is generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed.

```bash
xcodegen generate && open Nook.xcodeproj
```

Targets deploy to macOS 26 / iOS 26 and build with Swift 6 strict concurrency.

## Structure

```text
Packages/NookLibrary   the library itself — no SwiftUI anywhere in it
Nook/Sources           the SwiftUI app, which only talks to NookLibrary
```

### NookLibrary

| Area       | What lives there                                                     |
| ---------- | -------------------------------------------------------------------- |
| `Model/`   | SwiftData schema: `LibraryObject`, `Folder`, `LibraryCollection`, `Tag`, `Blob`, `DerivedContent` |
| `Store/`   | Content-addressed blob storage, thumbnails, library bootstrap        |
| `Privacy/` | The privacy broker and folder-inheritance resolver                    |
| `Access/`  | `LibraryService` — the Library Access API                             |
| `Import/`  | Classification and file-metadata extraction                           |

Three decisions shape everything else:

**Objects and blobs are separate.** Several objects — each with its own title,
tags, location and privacy state — can point at one stored copy of the bytes.
Blob bytes never enter the database; they live behind a `BlobStore` protocol so
that "everything local" today can become "originals on demand from iCloud"
later without touching the schema.

**The UI never queries the store.** Reads go through `LibraryService` and come
back as immutable `Sendable` snapshots. There is no path to a row that has not
passed the privacy broker first, so search, Siri, Spotlight and a future MCP
adapter cannot reach content the interface would have hidden. A locked object's
snapshot simply arrives without its blob, filename or notes.

**The schema is already CloudKit-shaped.** No unique constraints, defaults or
optionals everywhere, optional relationships with explicit inverses — so
turning on mirroring later is a configuration change, not a migration.

## Tests

```bash
cd Packages/NookLibrary && swift test
```
