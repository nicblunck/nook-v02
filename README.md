# Nook

A native personal library for macOS, iOS and iPadOS: import almost any file or
link, organise it with real folders plus flexible collections and tags, browse
it visually, and get the original back intact.

## Requirements

- macOS with Xcode 26 or newer
- Swift 6.2 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer

Nook currently targets macOS 26, iOS 26 and iPadOS 26. Building the iOS app or
share extension on a physical device also requires an Apple Developer account
with matching signing and App Group capabilities.

## Getting started

The Xcode project is generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated project is
committed so a fresh checkout opens immediately, but `project.yml` remains the
source of truth.

```bash
xcodegen generate
Scripts/check-generated-project.sh
open Nook.xcodeproj
```

Targets deploy to macOS 26 / iOS 26 and build with Swift 6 strict concurrency.
Select the `Nook-macOS` or `Nook-iOS` scheme in Xcode and run it normally. If
you are using a different Apple Developer account, replace `DEVELOPMENT_TEAM`
in `project.yml` before generating the project.

Make project-setting or target changes in `project.yml`, regenerate, and commit
the generated project alongside the spec. CI runs
`Scripts/check-generated-project.sh` and rejects stale project, plist,
entitlement, or shared-scheme output.

### Duplicate Nooks in the share sheet

The project builds one share extension per app and nothing here can build a
second: `Nook-macOS` embeds `NookMacShare`, `Nook-iOS` embeds
`NookShareExtension`, and the two carry different bundle identifiers.

A share sheet full of identical Nook rows is therefore never the project. macOS
lists one row per *registered copy* of an extension, and it registers a copy for
every `Nook.app` it has seen on disk — one per DerivedData folder, so one per
checkout and one per folder move, plus one per archive, plus anything left in
`/Applications`. Rebuilding does not clear them, because the old bundles are
still there.

```bash
Scripts/share-extensions.sh          # what is registered, and which copy is live
Scripts/share-extensions.sh --prune  # unregister everything but the live one
```

The script never deletes anything. A stale registration whose app bundle is
still on disk can come back the next time macOS scans, so the script prints
those bundles and leaves removing them to you.

## Structure

```text
Packages/NookLibrary   the library itself — no SwiftUI anywhere in it
Nook/Sources           the SwiftUI app, which only talks to NookLibrary
Nook/ShareExtension    iOS share sheet, writing into the same library
Nook/Resources         asset catalog and app icon
```

The icon is an [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
bundle — `Nook/Resources/AppIcon.icon`, layered SVGs plus `icon.json`, opened
and edited in Icon Composer. Xcode compiles the layered icon and generates the
flat variants from it, so there is no `AppIcon.appiconset` to keep in step.

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

### Hidden and Locked

Both are set from the interface, and every change to either — in both
directions — asks for Face ID, Touch ID or the device passcode before anything
moves. `DeviceAuthenticator` is the only thing that constructs a raised
`AccessContext`, and it is injected into `LibraryModel`, so the app's tests
answer for the device owner rather than needing one.

Hidden is a place, not a filter — the shape Photos uses, and it behaves like a
folder in its own right. Hiding something moves it there: an object detaches
from whatever folder held it, and a folder detaches from whatever parent held
it, the same way filing something into any other folder detaches it from
wherever it used to be. Hidden things are absent from Inbox, Recent, Favorites,
All Objects, folders, search and every count, whether or not anyone is
authenticated; opening Hidden (⇧⌘H, or the button at the foot of the sidebar)
opens that one door, and it closes again as soon as the user leaves. Unhiding
does not remember where something came from — an object surfaces in the Inbox,
a folder at the top level, the way anything with no folder of its own does.
Hiding a folder nested inside another hidden folder both marks it and promotes
it out from under that ancestor, straight to Hidden's own top level, which is
how a subfolder that only inherited Hidden gets moved out on its own.

Hidden and Recently Deleted sit in a row at the foot of the sidebar rather than
in the list: neither is somewhere the library's structure leads to. Hidden shows
no count, because how much someone is keeping out of sight is itself something
they are keeping out of sight.

Locked is the other half and works differently: locked content stays where it
is and arrives redacted — a door with a name and nothing behind it — until
whatever imposes the lock is authenticated, which may be an ancestor folder
rather than the item itself.

Hide and Lock are offered on what an item is in its own right. An object inside
a hidden folder is hidden without being hidden itself, and only the folder can
lift that, so snapshots carry the entity that imposed each protection rather
than a bare flag.

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

**The share extension cannot reach hidden destinations.** It lists folders
under `.standard` access, so a hidden folder is not offered as somewhere to save
to. The spec allows protected destinations there behind authentication; that
needs the authentication flow inside the extension as well.

## Tests

Run the core library suite directly with Swift Package Manager:

```bash
cd Packages/NookLibrary && swift test
```

After generating the Xcode project, run the app-layer tests with:

```bash
xcodebuild -project Nook.xcodeproj \
  -scheme Nook-macOS \
  -destination 'platform=macOS' \
  test
```

## Documentation

- [`Documentation/universal-file-library-complete-spec.md`](Documentation/universal-file-library-complete-spec.md)
  is the complete product and architecture specification.
- The package tests under `Packages/NookLibrary/Tests` document the expected
  import, privacy, search, organisation and external-tool behaviour.

## Development notes

- Keep persistence, privacy and import logic in `NookLibrary`; the app target
  should consume `LibraryService` snapshots rather than query SwiftData.
- Treat `LibraryToolSurface` as the read-only boundary for future external or
  model integrations.
- Do not hand-edit the generated Xcode project. Do not commit build products,
  user-specific Xcode state or local library data.
- The project does not currently publish a release build or enable iCloud; see
  **Not on yet** above for the capabilities still requiring provisioning.
