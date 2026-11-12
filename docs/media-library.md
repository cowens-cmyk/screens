# Media Library and background packs

The Media Library (`apps/mac/Sources/MediaLibraryView.swift`) is the media
bin: All Media and a category per folder down the side. A category is a
folder of that name at the top of the Media library (`MediaLibraryCategory`
in PresenterCore); Countdowns is `ServiceCountdown.folder` and Audio is the
Audio library. Moving media between categories is a refile, and syncs like
any other move between folders.

## Packs

Worship Backgrounds also holds packs: sets of related backgrounds, such as a
"Blossom" pack of ten motion loops. A pack is a folder right inside Worship
Backgrounds, so a background in the Blossom pack has `folder` set to
`Worship Backgrounds/Blossom`. There is no other record of a pack and no
schema change: other Macs, the browser editor and the library's own folder
view see the folder, and a background in a pack is still a worship
background (it loops by default and is offered as a background).

The rules live in `PresenterCore/Library/BackgroundPacks.swift` and are
tested in `BackgroundPacksTests.swift`:

- A pack is the second part of the folder path. Folders made by hand deeper
  inside a pack (`Worship Backgrounds/Christmas/2024`) belong to that pack.
- Pack names match without regard to case, as Finder's do. Where spellings
  differ, the pack shows the one most of its backgrounds carry.
- A name has no slash (a slash would make a folder inside the pack): `/` and
  `:` (Finder's slash as stored on disk) become `-`, and the name is trimmed.
- Out of a pack is the top of Worship Backgrounds (`Worship Backgrounds`).
- Renaming a pack refiles every background in it and keeps folders made
  inside it. Renaming to the name of another pack joins the two.
- Deleting a pack either moves its backgrounds to the top of Worship
  Backgrounds or deletes them (asks first, and says how many places use
  them).

The app side is `apps/mac/Sources/BackgroundPacksModel.swift`.

### Importing a folder

A Finder folder dropped on Worship Backgrounds (its row in the side list, its
grid, or picked with Import…) becomes a pack named after the folder.
`BackgroundPackImport`:

- Takes every picture and video in the folder and in the folders inside it,
  into the one pack. Music, PDFs, project files and the rest are left out.
- Skips hidden files and folders, the insides of packages (a Keynote deck or
  a Photos library dropped as a folder is not a pack), and `__MACOSX`.
- Reads the folder off the main thread; the copy then shows the media bin's
  usual progress bar ("Importing 3 of 12 · file name").
- Imports in the order Finder lists by name ("Blossom 2" before "Blossom 10").

Dropping the same folder again fills the pack it made: the import passes the
pack's file hashes to `MediaImporter.importFiles(skippingHashes:)`, and a
file whose contents are already in the pack, or that appears twice in the
folder, comes back as `.duplicate` instead of making a second item. Other
imports pass nothing and are unchanged.

Files dropped beside a folder go to the top of Worship Backgrounds. Files or
folders dropped on a pack's tile, or on the grid while a pack is open, go
into that pack. Folders dropped on any other category are imported as before:
their files, flattened into that category.

### In the media bin

Packs come first in the grid, by name, then the backgrounds in no pack. A
pack's tile shows four of its backgrounds, or the first when it has fewer,
and how many it holds. Clicking it opens it; the header's back button returns
to Worship Backgrounds. A search at the top of Worship Backgrounds lists
matching packs and matching backgrounds wherever they're kept.

Backgrounds inside a pack drag, right-click and play exactly like any other.
To move one: drag it onto a pack's tile to put it in, or onto Worship
Backgrounds in the side list or the back button to take it out; or
right-click › Move to Pack (No Pack, a pack, or New Pack…). A tile let go
over the grid it came from stays where it is.

Run-Only can open packs and browse them; nothing in a pack drags, imports,
renames or deletes there.

## Background or foreground

`MediaItem.classification` decides the layer a picture or video goes up on
(`CueMedia.firedLayer`). Background goes behind the slides, and Foreground
goes in front for videos (still graphics for pictures). The default follows
the folder: `MediaLibraryCategory.defaultClassification(forFolder:)` gives
Background for Worship Backgrounds (and packs inside it) and Foreground for
everything else.

- **Imports** (`MediaImporter`) set it from the folder they land in.
- **A move** across the Worship Backgrounds line (`AppModel.file`) switches
  it. A move that doesn't cross the line keeps a choice made by hand.
- **Existing media:** imports used to set Background for everything, so each
  library is set once by `Library.migrateMediaLayersByFolder` (marker
  `.migrated-media-layers-by-folder-v1` in the library folder).

Media dropped onto a slide is still that slide's background
(`CueMedia.droppedOnSlide`), whatever its classification.


## A video's thumbnail

A video's poster is taken at `MediaPosterStore.posterTime(of:)`: the item's
optional `posterSeconds` (Edit › the video › Trim › **Thumbnail** › Set, at the
preview playhead), else its in point. The poster's cache key and its on-disk
fingerprint (`MediaPosterStore.fingerprint(of:)`) include that time, so a new
frame replaces the old poster everywhere, and an item with no chosen frame
keeps the fingerprint it always had.
