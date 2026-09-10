# Xclip

[简体中文](README.md) · English

Xclip is a macOS clipboard manager for saving, searching and quickly pasting text, images and files.

## Download and install

Download the DMG or ZIP from [GitHub Releases](https://github.com/Anchor-anke/Xclip/releases/latest). Requires macOS 14+; the same universal package supports Apple Silicon and Intel.

Quit the previous version completely, then move `Xclip.app` to Applications. Choose Simplified Chinese or English under Settings → General → Interface language. Changes apply immediately and are remembered.

The current package uses local ad-hoc signing, without Developer ID signing or Apple notarization. Screenshots require Screen Recording permission; OCR on existing images does not. See the [development guide](docs/BUILDING.md) for installation and permissions.

## Current features

- Clipboard history and search for text, images and files, with source application records.
- A quick paste panel opened with `⌘;`, horizontal card browsing using the mouse wheel, and animated panel dismissal when dragging content out.
- Card context menus for editing, favoriting, pinning, copying, pasting and deleting, with undo for deletion.
- SQLite history and separate attachments, backups, restore and custom history storage.
- Clipboard stacks, quick replies, screenshots/OCR, and configurable AI, scripting, LAN sharing, upload and translation tools.
- Instant Simplified Chinese / English switching across tool pages, menus and application error messages.

See the [implementation status](docs/implementation-status.md) for scope and known limitations, and the [development guide](docs/BUILDING.md) for usage. AI, upload and translation services require your own configuration.

## Build and run

Running requires macOS 14+. Building requires Xcode with the macOS 26 SDK and Python 3. From the repository root:

```bash
./src/build.sh
open src/dist/Xclip.app
```

The default build produces a universal Apple Silicon / Intel app with local ad-hoc signing. The Xcode project is `src/Xclip.xcodeproj`, with the `Xclip` scheme. See the [development guide](docs/BUILDING.md) for build options, isolated tests and permissions.

Run `./scripts/package-release.sh` to package the current build as DMG, ZIP and `SHA256SUMS` in the root `dist/` directory. See the [release notes](docs/RELEASE.md) for validation scope and limitations.

## License

[MIT license](LICENSE) · [Copyright notices](NOTICE.md)
