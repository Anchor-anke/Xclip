import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Exercises synthetic images and injected async captures only: no screen access or UI.
@main
@MainActor
struct CaptureDesktopSnapshotTests {
    enum Failure: Error, Equatable { case displayUnavailable(CGDirectDisplayID) }

    /// A continuation barrier proves that all displays start before any can finish.
    /// Tests explicitly release each capture; they do not depend on sleeps or timing thresholds.
    @MainActor
    final class CaptureGate {
        private(set) var started: [CGDirectDisplayID] = []
        private(set) var finished: [CGDirectDisplayID] = []
        private var pending: [CGDirectDisplayID: CheckedContinuation<CGImage, Error>] = [:]
        private var startWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
        private var finishWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func capture(_ displayID: CGDirectDisplayID) async throws -> CGImage {
            defer {
                finished.append(displayID)
                if let waiter = finishWaiter, finished.count >= waiter.count {
                    finishWaiter = nil
                    waiter.continuation.resume()
                }
            }
            return try await withCheckedThrowingContinuation { continuation in
                precondition(pending[displayID] == nil, "Each display starts exactly once")
                pending[displayID] = continuation
                started.append(displayID)
                if let waiter = startWaiter, started.count >= waiter.count {
                    startWaiter = nil
                    waiter.continuation.resume()
                }
            }
        }

        func waitForStarts(_ count: Int) async {
            if started.count >= count { return }
            precondition(startWaiter == nil)
            await withCheckedContinuation { startWaiter = (count, $0) }
        }

        func waitForFinishes(_ count: Int) async {
            if finished.count >= count { return }
            precondition(finishWaiter == nil)
            await withCheckedContinuation { finishWaiter = (count, $0) }
        }

        func resolve(_ displayID: CGDirectDisplayID, _ result: Result<CGImage, Error>) {
            guard let continuation = pending.removeValue(forKey: displayID) else {
                preconditionFailure("A display must be pending before it can resolve")
            }
            continuation.resume(with: result)
        }
    }

    @MainActor
    final class MetadataGate {
        private var pending: CheckedContinuation<Int, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?

        func load() async -> Int {
            await withCheckedContinuation { continuation in
                pending = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }

        func waitForStart() async {
            if pending != nil { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func resolve(_ value: Int) {
            precondition(pending != nil, "A metadata load must start before resolving")
            let continuation = pending
            pending = nil
            continuation?.resume(returning: value)
        }
    }

    struct GeometryKey: Equatable {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let scale: Int
    }

    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
        print("PASS: \(message)")
    }

    static func image(_ seed: UInt8) -> CGImage {
        let pixels = Data([seed, 23, 47, 255, 53, seed, 79, 255,
                           83, 97, seed, 255, seed, 109, 127, 255])
        let provider = CGDataProvider(data: pixels as CFData)!
        return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    static func expectSizeError(_ message: String, expected: CaptureDesktopSnapshotError,
                                points: CGSize, scale: CGFloat, maximumPixels: Int = 60_000_000) {
        do {
            _ = try CaptureDesktopSnapshot.pixelSize(points: points, scale: scale, maximumPixels: maximumPixels)
            preconditionFailure("\(message): unexpectedly accepted")
        } catch {
            let matches: Bool
            switch (error as? CaptureDesktopSnapshotError, expected) {
            case (.invalidImageSize?, .invalidImageSize), (.imageTooLarge?, .imageTooLarge): matches = true
            default: matches = false
            }
            require(matches, message)
        }
    }

    static func pixelSizeTests() throws {
        let retina = try CaptureDesktopSnapshot.pixelSize(points: CGSize(width: 1440, height: 900), scale: 2)
        require(retina.width == 2880 && retina.height == 1800, "Retina capture uses physical pixels")
        let standard = try CaptureDesktopSnapshot.pixelSize(points: CGSize(width: 1920, height: 1080), scale: 1)
        require(standard.width == 1920 && standard.height == 1080, "A 1x display retains its pixel dimensions")
        let fractional = try CaptureDesktopSnapshot.pixelSize(points: CGSize(width: 3.25, height: 4.1), scale: 2)
        require(fractional.width == 7 && fractional.height == 9, "Fractional physical dimensions round up without losing edge pixels")
        let boundary = try CaptureDesktopSnapshot.pixelSize(points: CGSize(width: 6000, height: 2500), scale: 2)
        require(boundary.width == 12000 && boundary.height == 5000, "Exactly the default 60 million pixel limit is accepted")
        let custom = try CaptureDesktopSnapshot.pixelSize(points: CGSize(width: 3, height: 4), scale: 1, maximumPixels: 12)
        require(custom.width == 3 && custom.height == 4, "A custom pixel limit accepts its exact boundary")

        for (label, points) in [
            ("zero width", CGSize(width: 0, height: 1)),
            ("zero height", CGSize(width: 1, height: 0)),
            ("negative width", CGSize(width: -1, height: 1)),
            ("negative height", CGSize(width: 1, height: -1)),
            ("NaN width", CGSize(width: CGFloat.nan, height: 1)),
            ("NaN height", CGSize(width: 1, height: CGFloat.nan)),
            ("infinite width", CGSize(width: CGFloat.infinity, height: 1)),
            ("infinite height", CGSize(width: 1, height: CGFloat.infinity))
        ] {
            expectSizeError("Rejects \(label)", expected: .invalidImageSize, points: points, scale: 1)
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            expectSizeError("Rejects invalid scale \(scale)", expected: .invalidImageSize,
                            points: CGSize(width: 1, height: 1), scale: scale)
        }
        for limit in [0, -1] {
            expectSizeError("Rejects nonpositive pixel limit \(limit)", expected: .invalidImageSize,
                            points: CGSize(width: 1, height: 1), scale: 1, maximumPixels: limit)
        }
        expectSizeError("Rejects one pixel above a custom limit", expected: .imageTooLarge,
                        points: CGSize(width: 13, height: 1), scale: 1, maximumPixels: 12)
        expectSizeError("Rejects a pixel-area overflow even when each side fits", expected: .imageTooLarge,
                        points: CGSize(width: 8000, height: 8000), scale: 1)
        expectSizeError("Rejects scaling overflow before integer conversion", expected: .imageTooLarge,
                        points: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1), scale: 2)
        expectSizeError("Rejects dimensions outside representable integer range", expected: .imageTooLarge,
                        points: CGSize(width: CGFloat(Int.max), height: 1), scale: 1, maximumPixels: Int.max)
    }

    static func concurrentCollectionTests() async throws {
        let displayIDs: [CGDirectDisplayID] = [11, 22, 33]
        let images = [11: image(11), 22: image(22), 33: image(33)]
        let gate = CaptureGate()
        var published: [CGDirectDisplayID: CGImage]?
        let task = Task {
            published = try await CaptureDesktopSnapshot.collect(displayIDs: displayIDs) { try await gate.capture($0) }
        }
        await gate.waitForStarts(displayIDs.count)
        require(Set(gate.started) == Set(displayIDs) && gate.started.count == displayIDs.count,
                "All displays start once before any capture is released")
        require(gate.finished.isEmpty && published == nil, "The startup barrier holds every capture without publishing a partial snapshot")

        for (index, displayID) in [CGDirectDisplayID(33), 11, 22].enumerated() {
            gate.resolve(displayID, .success(images[Int(displayID)]!))
            await gate.waitForFinishes(index + 1)
            require(gate.finished[index] == displayID, "Completion order is controlled independently of display enumeration: \(displayID)")
            if index < displayIDs.count - 1 {
                require(published == nil, "No snapshot is published while another display remains pending")
            }
        }
        try await task.value
        require(published?.count == displayIDs.count, "Successful collection contains every requested display")
        for displayID in displayIDs {
            require(published?[displayID] === images[Int(displayID)], "Out-of-order completion retains the exact image for display \(displayID)")
        }
    }

    static func failureTests() async {
        let gate = CaptureGate()
        var published: [CGDirectDisplayID: CGImage]?
        let task = Task {
            published = try await CaptureDesktopSnapshot.collect(displayIDs: [11, 22, 33]) { try await gate.capture($0) }
        }
        await gate.waitForStarts(3)
        gate.resolve(11, .success(image(11)))
        await gate.waitForFinishes(1)
        require(published == nil, "One successful display does not publish a partial snapshot")
        gate.resolve(22, .failure(Failure.displayUnavailable(22)))
        await gate.waitForFinishes(2)
        gate.resolve(33, .success(image(33)))
        switch await task.result {
        case .success: preconditionFailure("A failed display must fail the complete snapshot")
        case .failure(let error):
            require(error as? Failure == .displayUnavailable(22), "Collection preserves the failing display's original error")
        }
        require(published == nil, "A failed collection discards both earlier and late successful images")
        require(gate.finished.count == 3, "Failure drains every pending capture before returning")
    }

    static func cancellationTests() async {
        let gate = CaptureGate()
        var published: [CGDirectDisplayID: CGImage]?
        let task = Task {
            published = try await CaptureDesktopSnapshot.collect(displayIDs: [11, 22]) { try await gate.capture($0) }
        }
        await gate.waitForStarts(2)
        task.cancel()
        // This fake deliberately ignores cancellation, as an OS capture may finish late.
        gate.resolve(22, .success(image(22)))
        await gate.waitForFinishes(1)
        require(published == nil, "Cancellation does not publish the first late successful image")
        gate.resolve(11, .success(image(11)))
        switch await task.result {
        case .success: preconditionFailure("A cancelled collection must not return images")
        case .failure(let error): require(error is CancellationError, "A cancelled collection reports CancellationError after late results")
        }
        require(published == nil && gate.finished.count == 2, "Cancellation drains and discards all late capture results")

        var captureCount = 0
        let early = Task {
            try await CaptureDesktopSnapshot.collect(displayIDs: [11]) { _ in
                captureCount += 1
                return image(11)
            }
        }
        early.cancel()
        switch await early.result {
        case .success: preconditionFailure("A pre-cancelled collection must not return images")
        case .failure(let error): require(error is CancellationError, "Cancellation before scheduling is preserved")
        }
        require(captureCount == 0, "Cancellation before scheduling avoids starting an OS capture")
    }

    static func invalidDisplayTests() async {
        for displayIDs: [CGDirectDisplayID] in [[], [11, 11], [kCGNullDirectDisplay], [11, kCGNullDirectDisplay]] {
            var captureCount = 0
            do {
                _ = try await CaptureDesktopSnapshot.collect(displayIDs: displayIDs) { _ in
                    captureCount += 1
                    return image(11)
                }
                preconditionFailure("Invalid display IDs \(displayIDs) must be rejected")
            } catch {
                if case .invalidDisplay? = error as? CaptureDesktopSnapshotError {
                    require(true, "Rejects invalid display IDs \(displayIDs)")
                } else {
                    preconditionFailure("Unexpected error for display IDs \(displayIDs): \(error)")
                }
            }
            require(captureCount == 0, "Invalid display IDs \(displayIDs) never start capture")
        }
    }

    static func permissionErrorTests() {
        let deniedCode = SCStreamError.Code.userDeclined.rawValue
        require(CaptureDesktopSnapshot.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: deniedCode)),
                "ScreenCaptureKit user-declined errors retain the permission guidance")
        require(!CaptureDesktopSnapshot.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: deniedCode + 1)),
                "Other ScreenCaptureKit failures are not mislabeled as permission denial")
        require(!CaptureDesktopSnapshot.isPermissionDenied(NSError(domain: "SyntheticOtherDomain", code: deniedCode)),
                "A matching numeric error in another domain is not permission denial")
    }

    static func metadataCacheTests() async throws {
        let original = GeometryKey(displayID: 11, width: 1440, height: 900, scale: 2)
        let changed = GeometryKey(displayID: 11, width: 1920, height: 1080, scale: 1)
        let cache = CaptureSnapshotMetadataCache<GeometryKey, Int>()
        var loads = 0
        let first = try await cache.value(for: original) { loads += 1; return 101 }
        let reused = try await cache.value(for: original) { loads += 1; return 999 }
        require(first == 101 && reused == 101 && loads == 1, "An unchanged display geometry reuses metadata with one load")
        let refreshed = try await cache.value(for: changed) { loads += 1; return 202 }
        require(refreshed == 202 && loads == 2, "Changed display geometry requires fresh metadata")
        cache.invalidate()
        let invalidated = try await cache.value(for: changed) { loads += 1; return 303 }
        require(invalidated == 303 && loads == 3, "Explicit invalidation requires a new metadata load for the same geometry")

        let failed = CaptureSnapshotMetadataCache<GeometryKey, Int>()
        var failureLoads = 0
        do {
            _ = try await failed.value(for: original) { failureLoads += 1; throw Failure.displayUnavailable(11) }
            preconditionFailure("A failed metadata load must not produce a value")
        } catch {
            require(error as? Failure == .displayUnavailable(11), "A metadata failure preserves its original error")
        }
        let recovered = try await failed.value(for: original) { failureLoads += 1; return 404 }
        require(recovered == 404 && failureLoads == 2, "A failed metadata load is retried rather than cached")

        let cancelled = CaptureSnapshotMetadataCache<GeometryKey, Int>()
        let cancelledGate = MetadataGate()
        var cancellationLoads = 0
        let cancelledTask = Task {
            try await cancelled.value(for: original) {
                cancellationLoads += 1
                return await cancelledGate.load()
            }
        }
        await cancelledGate.waitForStart()
        cancelledTask.cancel()
        cancelledGate.resolve(505)
        switch await cancelledTask.result {
        case .success: preconditionFailure("Cancelled metadata loading must not return a late value")
        case .failure(let error): require(error is CancellationError, "Cancellation rejects a late successful metadata load")
        }
        let afterCancellation = try await cancelled.value(for: original) { cancellationLoads += 1; return 606 }
        require(afterCancellation == 606 && cancellationLoads == 2, "A cancelled metadata load never populates the cache")

        let invalidatedWhileLoading = CaptureSnapshotMetadataCache<GeometryKey, Int>()
        let invalidationGate = MetadataGate()
        var invalidationLoads = 0
        let staleTask = Task {
            try await invalidatedWhileLoading.value(for: original) {
                invalidationLoads += 1
                return await invalidationGate.load()
            }
        }
        await invalidationGate.waitForStart()
        invalidatedWhileLoading.invalidate()
        invalidationGate.resolve(707)
        _ = await staleTask.result // The caller may receive it; the cache must not retain it.
        let afterInvalidation = try await invalidatedWhileLoading.value(for: original) { invalidationLoads += 1; return 808 }
        require(afterInvalidation == 808 && invalidationLoads == 2, "Invalidating during a load prevents its late metadata from repopulating the cache")
        let latest = try await invalidatedWhileLoading.value(for: original) { invalidationLoads += 1; return 999 }
        require(latest == 808 && invalidationLoads == 2, "The replacement load becomes the reusable metadata value")
    }

    static func freshImageTests() async throws {
        var captures = 0
        let firstImage = image(41), secondImage = image(42)
        let first = try await CaptureDesktopSnapshot.collect(displayIDs: [11]) { _ in
            captures += 1
            return firstImage
        }
        let second = try await CaptureDesktopSnapshot.collect(displayIDs: [11]) { _ in
            captures += 1
            return secondImage
        }
        require(captures == 2, "Each screenshot request calls capture again even for the same display")
        require(first[11] === firstImage && second[11] === secondImage && first[11] !== second[11],
                "Consecutive screenshots return newly captured image objects rather than cached pixels")
    }

    static func main() async throws {
        try pixelSizeTests()
        permissionErrorTests()
        try await metadataCacheTests()
        try await freshImageTests()
        try await concurrentCollectionTests()
        await failureTests()
        await cancellationTests()
        await invalidDisplayTests()
        print("CaptureDesktopSnapshotTests: \(checks) checks passed; synthetic images only, no desktop capture or UI.")
    }
}
