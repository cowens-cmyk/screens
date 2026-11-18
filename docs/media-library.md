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
preview playhead), else 10 seconds past its in point
(`MediaPosterStore.defaultPosterOffset`): the first frame of most church
videos is black or a title card. A video shorter than that gives the frame
halfway through what plays (in point to out point). The poster's cache key
and its on-disk fingerprint (`MediaPosterStore.fingerprint(of:)`) include that
time, so a new frame replaces the old poster everywhere. A picture's
fingerprint never changes.

## The church's own categories

Beside the built-in categories, the church makes its own in the media bin's
side list: **New Category…** under the categories, a name and an icon (the
Hope Students or Hope logo, or one of a set of symbols). Right-click one ›
Edit Category… or Delete Category…. Hope Students, with the Students logo, is
there until the list is changed for the first time.

A church category is a folder at the top of Media, like a built-in one, so
what's in it syncs as any move does. The list (name and icon) is
`SlideBuildingSettings.mediaCategories`, the church-wide settings, so every
Mac shows the same categories. Rules in `PresenterCore/Library/MediaCategories.swift`
(tested in `MediaCategoriesAndMissingTests.swift`), the app side in
`apps/mac/Sources/MediaCategoriesModel.swift`:

- A name is a folder name: `/` and `:` become `-`. It can't be a built-in
  category's (or All Media), or another church category's, without regard to
  case.
- Renaming refiles everything in it and keeps folders made inside it.
- Deleting takes it off the list only. Its media stays in the folder and in
  All Media; making the category again brings it back.
- Media in a church category plays as anything outside Worship Backgrounds
  does: in front, once.
- Drop files on its row or grid to import into it; drag tiles onto its row,
  or right-click › Move to, to file them there.

A Mac on a build from before 0.41 shows only the built-in categories, and a
change to the church-wide settings made there can drop the list. Update every
Mac.

## Where the files are

Every picture, video and song added to Screens (dropped on a slide or the
plan, imported into the Media Library, brought in with a ProPresenter or
Keynote import, or downloaded from the church library) is copied into one
folder, and Screens plays only from it: `~/Library/Application
Support/Screens/Library/blobs` on this Mac, or the `blobs` folder on the
drive chosen in Settings › Media & Video › Media Storage (Show in Finder
there opens it). A slide holds a media item's id, never the path of the
file it came from, so deleting or moving the original changes nothing.

The files are named by their SHA-256 (sync, backups and the drive move check
each copy against its name), so the folder isn't for sorting by hand: the
Media Library's categories are where media is organized.

## Missing media when a plan opens

`PlanMissingMediaPrompt` (`apps/mac/Sources/PlanMissingMediaCheck.swift`)
looks through a plan when it's opened: each item's presentation (every slide,
section and the deck's own background, through `MediaReferences`), media,
audio and playlist, in every version. Anything that can't play is listed in a
sheet straight away (`PlanMissingMedia` in PresenterCore):

- **File not on this Mac**: the item is in the library, its file isn't in
  the media folder.
- **Deleted from the library**: a slide or the plan still points at it.

Each row says which plan items use it. **Choose File…** puts a file behind it
(or brings a deleted one back under the same id, so every slide using it is
fixed); **Find in a Folder…** searches a folder for exact copies by content.
Run-Only sees the list without the buttons.

It waits 1.5 seconds after the plan opens, and up to 20 more while files are
downloading from the church library, then says if the media drive is
unplugged or files are still downloading. The list updates as files arrive.
It shows once per plan per launch unless something else goes missing.
