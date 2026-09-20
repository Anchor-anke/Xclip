import CoreGraphics
import AppKit
import Foundation
import ScreenCaptureKit
import os

enum CaptureDesktopSnapshotError: Error {
    case invalidDisplay, invalidImageSize, imageTooLarge
}

/// Reuse capture configuration, never captured pixels. Invalidation also prevents
/// an in-flight metadata lookup from restoring an obsolete display configuration.
@MainActor
final class CaptureSnapshotMetadataCache<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?
    private var generation: UInt = 0

    func value(for key: Key, load: () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let cached, cached.key == key { return cached.value }
        cached = nil
        let current = generation
        let value = try await load()
        try Task.checkCancellation()
        if generation == current { cached = (key, value) }
        return value
    }

    func invalidate() { cached = nil; generation &+= 1 }
}

/// One user-requested desktop freeze. Images stay in memory for this capture only.
@MainActor
enum CaptureDesktopSnapshot {
    private struct DisplaySignature: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let rotation: Double
    }
    private static let filters = CaptureSnapshotMetadataCache<[DisplaySignature], [CGDirectDisplayID: SCContentFilter]>()
    private static let displayObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in
        Task { @MainActor in filters.invalidate() }
    }

    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let native = error as NSError
        return native.domain == SCStreamErrorDomain && native.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func images(for displayIDs: [CGDirectDisplayID]) async throws -> [CGDirectDisplayID: CGImage] {
        try validate(displayIDs)
        try Task.checkCancellation()
        _ = displayObserver
        let signature = try displayIDs.map { id -> DisplaySignature in
            guard CGDisplayIsActive(id) != 0, let mode = CGDisplayCopyDisplayMode(id) else {
                throw CaptureDesktopSnapshotError.invalidDisplay
            }
            return DisplaySignature(id: id, bounds: CGDisplayBounds(id), width: mode.width, height: mode.height,
                                    pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, rotation: CGDisplayRotation(id))
        }
        do {
            let prepared = try await filters.value(for: signature) {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                let displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
                guard displayIDs.allSatisfy({ displays[$0] != nil }) else { throw CaptureDesktopSnapshotError.invalidDisplay }
                let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                // A future Xclip window must not reuse a filter that could not exclude its owner.
                if ownApplications.isEmpty { filters.invalidate() }
                return Dictionary(uniqueKeysWithValues: displayIDs.map { id in
                    (id, SCContentFilter(display: displays[id]!, excludingApplications: ownApplications, exceptingWindows: []))
                })
            }
            CaptureStartupTiming.mark("enumeration")

            let images = try await collect(displayIDs: displayIDs) { displayID in
                guard let filter = prepared[displayID] else { throw CaptureDesktopSnapshotError.invalidDisplay }
                let size = try pixelSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
                let configuration = SCStreamConfiguration()
                configuration.width = size.width
                configuration.height = size.height
                configuration.showsCursor = false
                configuration.scalesToFit = false
                // Leaving colorSpaceName unset preserves the display's color space.
                // Passing the CGImage directly also avoids PNG encoding and two full image decodes.
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard image.width == size.width, image.height == size.height else {
                    throw CaptureDesktopSnapshotError.invalidImageSize
                }
                return image
            }
            CaptureStartupTiming.mark("capture")
            return images
        } catch {
            filters.invalidate()
            throw error
        }
    }

    /// Start every display capture together, and return only after all have succeeded.
    /// An injected capture lets tests check concurrency and cancellation without screen access.
    static func collect(displayIDs: [CGDirectDisplayID],
                        capture: @escaping @MainActor (CGDirectDisplayID) async throws -> CGImage) async throws -> [CGDirectDisplayID: CGImage] {
        try validate(displayIDs)
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
            for displayID in displayIDs {
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    let image = try await capture(displayID)
                    try Task.checkCancellation()
                    return (displayID, image)
                }
            }
            var images: [CGDirectDisplayID: CGImage] = [:]
            for try await (displayID, image) in group { images[displayID] = image }
            try Task.checkCancellation()
            return images
        }
    }

    nonisolated static func pixelSize(points: CGSize, scale: CGFloat, maximumPixels: Int = 60_000_000) throws -> (width: Int, height: Int) {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0, maximumPixels > 0 else {
            throw CaptureDesktopSnapshotError.invalidImageSize
        }
        let pixelWidth = (points.width * scale).rounded(.up)
        let pixelHeight = (points.height * scale).rounded(.up)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth <= CGFloat(maximumPixels), pixelHeight <= CGFloat(maximumPixels),
              let width = Int(exactly: pixelWidth), let height = Int(exactly: pixelHeight),
              width > 0, height > 0, width <= maximumPixels / height else {
            throw CaptureDesktopSnapshotError.imageTooLarge
        }
        return (width, height)
    }

    private static func validate(_ displayIDs: [CGDirectDisplayID]) throws {
        guard !displayIDs.isEmpty, Set(displayIDs).count == displayIDs.count,
              !displayIDs.contains(kCGNullDirectDisplay) else { throw CaptureDesktopSnapshotError.invalidDisplay }
    }
}

/// Local timing only: no pixels, window titles, file paths, or screen-content metadata.
@MainActor
enum CaptureStartupTiming {
    private static let logger = os.Logger(subsystem: "local.cclip.app", category: "ScreenshotStartup")
    private static var startedAt: TimeInterval?

    static func begin() { startedAt = ProcessInfo.processInfo.systemUptime }
    static func mark(_ stage: String) {
        guard let startedAt else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        logger.notice("stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds, privacy: .public)")
    }
    static func finish() { startedAt = nil }
}
