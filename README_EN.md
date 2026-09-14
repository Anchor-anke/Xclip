# Xclip

[简体中文](README.md) · English

Xclip is a macOS clipboard manager for saving, searching and quickly pasting text, images and files.

## Download and install

Download the DMG or ZIP from [GitHub Releases](https://github.com/Anchor-anke/Xclip/releases/latest). Requires macOS 14+; the same universal package supports Apple Silicon and Intel.

The current version is **0.4.1 (build 5)**. Choose Simplified Chinese or English under Settings → General → Interface language. Changes apply immediately and are remembered.

DMG / ZIP packages contain both `安装 Xclip.app` (Install Xclip) and `Xclip.app`. Open the installer and select the existing installation location. It asks the previous copy to quit normally, replaces it and reopens it, preserving history and settings. Installation stops if the app cannot quit normally, and other copies are not removed. Extract the entire ZIP first and keep both apps together. Alternatively, quit the previous version completely and manually replace it. Back up your data before upgrading; see the [migration and rollback guide](docs/UPGRADING.md).

The 0.4.1 release uses a stable local development certificate, without Developer ID signing or Apple notarization. Screenshots require Screen Recording permission; OCR on existing images does not. See the [development guide](docs/BUILDING.md) for installation and permissions.

## Current features

- Clipboard history and search for text, images and files, with source application records.
- A quick paste panel opened with `⌘;`, horizontal card browsing using the mouse wheel, and animated panel dismissal when dragging content out.
- Right-click cancellation during a drag without releasing the left button; the quick panel reappears after cancellation.
- On-demand loading of large content, a bounded thumbnail cache, and preview cleanup when the panel closes. Cleared shortcuts remain disabled after restarting.
- Card context menus for editing, favoriting, pinning, copying, pasting and deleting, with undo for deletion.
- SQLite history and separate attachments, backups, restore and custom history storage.
- Clipboard stacks, quick replies, screenshot annotation, image OCR, and configurable AI, scripting, LAN sharing, upload and translation tools.
- The screenshot shortcut opens selection and a floating annotation toolbar directly. Add arrows, text or mosaics before copying or saving. Customize the shortcut under Settings → Shortcuts → Screenshot. See the [capture guide (Chinese)](docs/screenshot-annotation.md).
- Scrolling capture, screen recording and MP4/GIF/WebP export, image pins, table/barcode recognition and offline formula rendering. Translation and image-to-formula recognition use your configured services. See the [0.4.0 workflow and validation scope (Chinese)](docs/pixpin-complete-validation.md).
- Instant Simplified Chinese / English switching across tool pages, menus and application error messages.

See the [implementation status](docs/implementation-status.md) for scope and known limitations, and the [development guide](docs/BUILDING.md) for usage. AI, upload and translation services require your own configuration.

The repository also includes an independent [Windows core preview](windows/README.md). Windows device testing remains pending; this release provides macOS downloads.

## Build and run

Running requires macOS 14+. Building requires Xcode with the macOS 26 SDK, Python 3 and CMake. From the repository root:

```bash
./src/build.sh
open src/dist/Xclip.app
```

The default build produces a universal Apple Silicon / Intel app and reuses the installed signing certificate. A new installation selects the only available identity, or uses ad-hoc signing when none is available. Missing previously used certificates or ambiguous identities stop the build. The Xcode project is `src/Xclip.xcodeproj`, with the `Xclip` scheme. See the [development guide](docs/BUILDING.md) for build options, isolated tests and permissions.

Run `./scripts/package-release.sh` to package a build signed with a stable certificate and its overwrite installer as DMG, ZIP and `SHA256SUMS` in the root `dist/` directory. Set `XCLIP_PACKAGE_OUTPUT_DIR` to use a separate candidate output directory and preserve existing release assets. See the [release notes](docs/RELEASE.md) for validation scope and limitations.

## License

[MIT license](LICENSE) · [Copyright notices](NOTICE.md)
