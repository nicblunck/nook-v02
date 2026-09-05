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
Nook/ShareExtension    iOS share sheet, writing into the same library
```

### NookLibrary

| Area       | What lives there                                                     |
| ---------- | -------------------------------------------------------------------- |
| `Model/`   | SwiftData schema: `LibraryObject`, `Folder`, `LibraryCollection`, `Tag`, `Blob`, `DerivedContent` |
| `Store/`   | Content-addressed blob storage, thumbnails, library bootstrap        |
| `Privacy/` | The privacy broker and folder-inheritance resolver                    |
| `Access/`  | `LibraryService` — the Library Access API                             |
| `Import/`  | Classification and file-metadata extraction                           |
| `Search/`  | Text extraction feeding the derived store                             |
| `Intelligence/` | The read-only tool surface and the provider abstraction          |

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

### External access

`LibraryToolSurface` is the one surface external consumers talk to — an MCP
adapter, an on-device model, a hosted one. It is read-only by construction
rather than by policy: there are no write operations to call. Every result
comes back through `LibraryService`, so the privacy broker has already run, and
digests deliberately carry no filesystem paths — a path is useless to a model
and a way around the library's own rules.

`IntelligenceProvider` keeps any single vendor from becoming the permanent
interface. Providers declare whether they process content remotely, because the
user is entitled to know that before choosing one.

## Not on yet

**iCloud sync** is a one-line switch — `Library.bootstrap(locations:syncMode:)` —
rather than a migration, because the schema has been CloudKit-shaped from the
start. Turning it on needs a CloudKit container provisioned under the developer
account plus the iCloud entitlement, so it stays `.local` until then. Mirroring
would cover the metadata store only; originals stay behind `BlobStore`.

**The app group** (`group.com.nicolasblunck.nook`) has to exist for the share
extension to write into the app's library. Until it does, both fall back to
their own Application Support directory and the extension saves somewhere the
app cannot see.

**No intelligence provider is implemented.** The abstraction and the tool
surface are built and tested; nothing plugs into them yet. That ordering is the
spec's: the library has to be useful on its own before it is useful to a model.

**Hidden and Locked have no UI.** Enforcement is built and tested throughout,
but nothing yet raises the access context above `.standard`, so there is no way
to hide or lock anything from the interface. That split is deliberate: the spec
puts the architecture in the MVP and the authentication flow after it.

## Tests

```bash
cd Packages/NookLibrary && swift test
```
