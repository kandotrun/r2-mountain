<div align="center">

<img src="docs/images/readme-hero.svg" width="100%" alt="R2 Mountain at a glance. On the left, the app icon in sunrise orange: a snow-capped navy mountain with a white arrow pointing up into the sky. On the right, a Finder window with R2 Mountain selected under Locations in the sidebar. The window lists the Footage folder: a progress bar grows next to the 38.2 GB feature-4K.mov, a 2.4 GB zip shows a cloud icon (not downloaded to this Mac), and an 8.7 GB mp4 shows a green check (done). From the lower left, a card for take-2.mov (12.6 GB) is about to be dropped into the window along a dashed arrow.">

# R2 Mountain

**Cloudflare R2, right in Finder.**<br>
Drag in big files and they upload. If a transfer stops partway, it picks up where it left off.

A macOS app made only for Cloudflare R2.<br>
It shows your bucket in the Finder sidebar, and you can also upload from the menu bar and the app window.

<sub>The R2 dashboard can't upload large files, so I built this for my own Mac.</sub>

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-15171a?logo=apple&logoColor=white)](#-getting-started)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white&labelColor=15171a)](#-architecture)
[![Cloudflare R2 only](https://img.shields.io/badge/Cloudflare-R2%20only-F38020?logo=cloudflare&logoColor=white&labelColor=15171a)](#-features)
[![Finder File Provider](https://img.shields.io/badge/Finder-File%20Provider-2563eb?labelColor=15171a)](#%EF%B8%8F-finder-operations)
[![UI Liquid Glass](https://img.shields.io/badge/UI-Liquid%20Glass-2563eb?labelColor=15171a)](#-screens)
[![License: MIT](https://img.shields.io/badge/license-MIT-2563eb?labelColor=15171a)](LICENSE)

**[Getting started](#-getting-started)**&emsp;**[Features](#-features)**&emsp;**[Finder operations](#%EF%B8%8F-finder-operations)**&emsp;[Architecture](#-architecture)&emsp;[日本語で読む](README.ja.md)

</div>

> [!NOTE]
> The app's interface and the documents in `docs/` are in Japanese.
>
> Formerly S3 Mountain. The bundle ID (`run.kan.s3mountain`), App Group, and keychain group keep their old names so settings, credentials, and the Finder connection carry over.

## 🎬 Screens

<div align="center">

<table>
  <tr>
    <td align="center" width="33%"><img src="docs/images/app-window.png" width="300" alt="R2 Mountain's main window, in Japanese. The sidebar shows the bucket “drive” and recent destinations. The middle lists the s3-mountain-tests folder (two folders and one file, with size and upload date columns). The transfers panel on the right lists finished uploads, and a path bar runs along the bottom."></td>
    <td align="center" width="33%"><img src="docs/images/drop-folder-row.png" width="300" alt="A file dragged over the row of a folder named UIテスト-203944. Only that row is highlighted in orange, showing the file will be uploaded into that folder."></td>
    <td align="center" width="33%"><img src="docs/images/drop-current-folder.png" width="300" alt="A file dragged over an empty part of the list. The whole list gets an orange outline, showing the file will be uploaded into the folder on screen."></td>
  </tr>
  <tr>
    <td align="center"><b>📁 Pick a folder</b><br>Open the destination in<br>a Finder-style list</td>
    <td align="center"><b>🎯 Drop on a row</b><br>Upload into<br>that folder</td>
    <td align="center"><b>⬇️ Drop anywhere</b><br>Upload into the<br>folder on screen</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/uploading.png" width="300" alt="The transfers panel while a 2.15 GB file uploads, in Japanese. It shows that one file is uploading, an overall progress bar, and a row reading 67.1 MB of 2.15 GB at 15.5 MB per second with about 2 minutes left, plus the destination key and pause and cancel buttons. The toolbar shows a progress ring."></td>
    <td align="center"><img src="docs/images/finder-delete.png" width="220" alt="Finder's confirmation dialog, in Japanese: are you sure you want to delete “空フォルダ改名”? The item will be deleted immediately and this can't be undone. Cancel and Delete buttons."></td>
    <td align="center"><img src="docs/images/icon-light.png" width="110" alt="The app icon in light mode"> <img src="docs/images/icon-dark.png" width="110" alt="The app icon in dark mode. The background turns black and the snow and arrow glow orange."></td>
  </tr>
  <tr>
    <td align="center"><b>📈 Progress and time left</b><br>Speed, time left,<br>pause and resume</td>
    <td align="center"><b>🗑️ Delete with confirmation</b><br>Finder's Delete Immediately<br>also deletes on R2</td>
    <td align="center"><b>🏔️ Icon</b><br>Liquid Glass layers<br>for light and dark</td>
  </tr>
</table>

<sub>Captured on macOS 27.2 (November 4–5, 2026). File names are test data.</sub>

</div>

## ✨ Features

- 🗂️ **Mounted in Finder** — Your bucket appears under Locations in the Finder sidebar. Open, copy, rename, move, and delete files and folders just as you would anywhere else in Finder.
- ⬆️ **Big files pick up where they left off** — Files of 64 MiB and up go as multipart uploads. If a transfer stops, the app checks which parts made it and sends only the rest.
- 🪶 **Saves disk space** — When a Finder upload finishes, the copy on your Mac is removed automatically, but the file stays in Finder. Opening it downloads it from R2 again.
- 📁 **Pick a folder, then drop** — Open a folder in the app window and drop files on it, or choose a destination from the menu bar. You can make new folders right there.
- 🔒 **Never deletes what you can't see** — When you delete a folder, if R2 has files in it that Finder hasn't shown yet, the delete is canceled and the folder is listed again so those files appear.
- 🧭 **Never overwrites** — When names collide, the new item becomes “name 2” instead of merging or overwriting.
- 🔑 **Secrets stay in the Keychain** — The secret access key is stored only in the Keychain, in a group shared by the app and its extension.
- 🔔 **Progress and notifications** — Speed and time left, notifications when uploads finish or fail, and a menu bar icon that changes when something is wrong.

## 🗂️ Finder operations

| What you do in Finder | What happens on R2 |
| --- | --- |
| Open a folder | Lists that folder (`ListObjectsV2`) |
| Open or copy a file | Downloads it from R2 |
| Drag in files or folders | Uploads them, then removes the copy on your Mac to save space |
| New Folder | Creates a `name/` folder marker |
| Rename or move | Copies to the new key, then deletes the original (files over 5 GiB are copied in parts) |
| Delete Immediately (⌥⌘⌫) | Deletes after confirmation. A folder is deleted with everything in it |
| Change R2 some other way | While the app is running, it checks about every 90 seconds and updates Finder |

> [!IMPORTANT]
> The Trash isn't used. ⌘⌫ (Move to Trash) does nothing, so use Delete Immediately from the right-click menu or press ⌥⌘⌫.

> [!TIP]
> R2 has no rename operation, so renaming or moving a big folder takes as long as copying everything in it.

## 🚀 Getting started

### 1. Build and run

You need macOS 26 or later, Xcode 27 (Swift 6), [just](https://github.com/casey/just), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/kandotrun/r2-mountain.git
cd r2-mountain
just run
```

> [!NOTE]
> The Finder extension needs development signing. Set your signing team with `DEVELOPMENT_TEAM` in `project.yml`.
> The first `just run` (`just build-signed`) registers this Mac as a device in your Apple Developer account so that automatic signing works.

### 2. Get an R2 API token

<details>
<summary>How to make the token</summary>

1. In the Cloudflare dashboard, open R2 and create a new token from the API token settings.
2. Give it the **Object Read & Write** permission, and limit it to the bucket you'll use.
3. Copy the **Access Key ID** and **Secret Access Key** shown after it's created. The secret is shown only on this screen.
4. Also copy the **Account ID** shown on the R2 page. It's a different value from the Access Key ID.

</details>

### 3. Connect and show in Finder

1. Click the mountain icon in the menu bar, open 接続設定… (Connection settings), and save your account ID, bucket, access key ID, and secret.
2. Turn on Finder に表示 (Show in Finder).
3. **R2 Mountain** appears under Locations in the Finder sidebar (`~/Library/CloudStorage/R2Mountain-<bucket>`).

Debug builds use File Provider's Testing Mode, so you don't need to turn on the extension in System Settings.

## ⌨️ Keyboard shortcuts in the window

| Action | Keys |
| --- | --- |
| Open folder | Return or ⌘↓ |
| Go to enclosing folder | ⌘↑ |
| Back, forward | ⌘[, ⌘] |
| New folder | ⇧⌘N |
| Choose files to upload | ⌘O |
| Reload | ⌘R |

## 🧱 Architecture

| Part | What it does |
| --- | --- |
| `Packages/MountainCore` | The S3 client for R2 (SigV4), resumable uploads, a SQLite store that maps R2 keys to Finder item IDs, and the Finder operations on R2 (create folder, move, delete). No UI dependencies; tested with `swift test`. |
| `App` | The SwiftUI and AppKit app: menu bar, main window, settings, and Finder integration |
| `FileProvider` | The File Provider extension. It only connects Apple's API to MountainCore. |
| `Shared` | Connection settings and credentials shared by the app and the extension |

```
App/            # Menu bar, window, settings, Finder on/off, app icon (AppIcon.icon)
FileProvider/   # Replicated extension (enumerate, download, create, modify, delete)
Shared/         # Connection settings in the App Group, shared Keychain
Packages/MountainCore/
  Sources/MountainCore/
    S3/         # Signing, requests, XML, download, copy, batch delete
    Upload/     # Upload engine for the menu bar app, display text
    Browse/     # Folder paths, listings, history, recent destinations
    Mount/      # Item map and change log, uploads to an exact key, move and delete
    Host/       # Registering the Finder domain, periodic checks
  Tests/        # Swift Testing unit tests
scripts/        # Tools for testing against real R2 (development only)
docs/           # Specs, implementation plans, validation log
```

## 🧪 Development

```sh
just test          # MountainCore unit tests (no credentials needed)
just lint          # Static checks with swift format
just build-signed  # Build with development signing
just run           # Build and launch
```

How to test against a real R2 bucket is in [Testing against real R2](docs/r2-integration-testing.md) (Japanese). Test objects go only under `s3-mountain-tests/`, and cleanup deletes only the keys the test created.

## ✅ What's verified, and honest limits

Verified on macOS 27.2 with a real R2 bucket:

- **Finder**: listing, downloads (MD5 match), 3 MB and 150 MB uploads, removing the local copy after upload, new folders, renaming and moving files and folders, delete with confirmation, picking up files added or deleted on R2
- **Safety**: calling off a delete when a folder has files Finder hasn't shown yet, “name 2” when names collide
- **App**: a 2 GiB upload, dropping on a folder row and on the open folder, keyboard navigation
- **Transfer core**: resuming after a force quit (512 MiB, downloaded back with a matching SHA-256)
- **Tests**: 239 in `just test`

Not verified yet:

- Uploads of tens of GB through Finder, resuming after sleep
- Using every screen with VoiceOver

Known limits:

- Finder tags and extended attributes aren't saved to R2
- The app's interface is in Japanese only

Details are in the [validation log](docs/validation.md) (Japanese).

## 📚 Docs

All of these are in Japanese.

| Document | About |
| --- | --- |
| [Phase 1 spec](docs/superpowers/specs/2026-11-04-s3-mountain-phase1-design.md) | The menu bar uploader |
| [Phase 1 implementation plan](docs/superpowers/plans/2026-11-04-s3-mountain-phase1-implementation.md) | How phase 1 was built |
| [Phase 2 spec](docs/superpowers/specs/2026-11-05-s3-mountain-phase2-finder-mount-design.md) | The Finder mount (File Provider) |
| [Phase 2 implementation plan](docs/superpowers/plans/2026-11-05-s3-mountain-phase2-finder-mount.md) | How phase 2 was built |
| [Testing against real R2](docs/r2-integration-testing.md) | How to run the tests that use credentials |
| [Validation log](docs/validation.md) | Results checked on a real Mac and real R2 |

## 📄 License

[MIT](LICENSE)
