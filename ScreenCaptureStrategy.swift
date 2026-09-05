import CoreGraphics
import Foundation

enum ScreenCaptureBackend: Equatable {
    case legacyScreencaptureCLI
    case nativeRegionSelection
}

enum ScreenCaptureStrategy {
    /// macOS 15.2+ (including Tahoe 26) must not spawn `/usr/sbin/screencapture`.
    /// That CLI re-triggers Screen Recording consent even after the app is granted.
    static func preferred(
        for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> ScreenCaptureBackend {
        if version.majorVersion > 15 {
            return .nativeRegionSelection
        }
        if version.majorVersion == 15 && version.minorVersion >= 2 {
            return .nativeRegionSelection
        }
        return .legacyScreencaptureCLI
    }
}

enum ScreenCaptureGeometry {
    /// Convert a Cocoa global rect (`NSWindow.convertToScreen`, origin at the
    /// bottom-left of the primary display) into the Quartz global rect that
    /// `SCScreenshotManager.captureImage(in:)` expects (origin at the top-left
    /// of the primary display). Passing Cocoa coords captures a vertically
    /// mirrored region — usually wallpaper.
    static func quartzScreenRect(fromCocoa rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

enum ScreenSnapshotCrop {
    /// Map a Cocoa selection rect into pixel space of a display snapshot.
    /// Snapshot images use top-left origin, so this is the same y-flip as
    /// `quartzScreenRect`, scaled by the snapshot's pixel size.
    static func pixelRect(
        cocoaRect: CGRect,
        screenCocoaFrame: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        let local = cocoaRect.intersection(screenCocoaFrame)
        guard !local.isNull,
              local.width >= 1,
              local.height >= 1,
              screenCocoaFrame.width > 0,
              screenCocoaFrame.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(imageWidth) / screenCocoaFrame.width
        let scaleY = CGFloat(imageHeight) / screenCocoaFrame.height
        var rect = CGRect(
            x: (local.minX - screenCocoaFrame.minX) * scaleX,
            y: (screenCocoaFrame.maxY - local.maxY) * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        rect = rect.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        return rect
    }

    static func crop(
        _ image: CGImage,
        cocoaRect: CGRect,
        screenCocoaFrame: CGRect
    ) -> CGImage? {
        guard let rect = pixelRect(
            cocoaRect: cocoaRect,
            screenCocoaFrame: screenCocoaFrame,
            imageWidth: image.width,
            imageHeight: image.height
        ) else {
            return nil
        }
        return image.cropping(to: rect)
    }

    /// Place per-display crops onto one canvas in Cocoa global coordinates.
    /// Cross-display selections keep every intersecting monitor; a single
    /// full-canvas piece is returned as-is to avoid an extra bitmap copy.
    static func composite(
        pieces: [(image: CGImage, cocoaRect: CGRect)],
        canvasCocoa: CGRect
    ) -> CGImage? {
        let valid = pieces.filter {
            $0.cocoaRect.width >= 1
                && $0.cocoaRect.height >= 1
                && $0.image.width > 0
                && $0.image.height > 0
        }
        guard !valid.isEmpty,
              canvasCocoa.width >= 1,
              canvasCocoa.height >= 1 else {
            return nil
        }

        if valid.count == 1 {
            let piece = valid[0]
            if pieceCoversCanvas(piece.cocoaRect, canvasCocoa) {
                return piece.image
            }
        }

        var scale: CGFloat = 1
        for piece in valid {
            if piece.cocoaRect.width > 0 {
                scale = max(scale, CGFloat(piece.image.width) / piece.cocoaRect.width)
            }
            if piece.cocoaRect.height > 0 {
                scale = max(scale, CGFloat(piece.image.height) / piece.cocoaRect.height)
            }
        }

        let width = max(1, Int((canvasCocoa.width * scale).rounded()))
        let height = max(1, Int((canvasCocoa.height * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        for piece in valid {
            let dest = CGRect(
                x: (piece.cocoaRect.minX - canvasCocoa.minX) * scale,
                y: (canvasCocoa.maxY - piece.cocoaRect.maxY) * scale,
                width: piece.cocoaRect.width * scale,
                height: piece.cocoaRect.height * scale
            )
            ctx.draw(piece.image, in: dest)
        }
        return ctx.makeImage()
    }

    private static func pieceCoversCanvas(_ piece: CGRect, _ canvas: CGRect) -> Bool {
        abs(piece.minX - canvas.minX) < 0.5
            && abs(piece.minY - canvas.minY) < 0.5
            && abs(piece.width - canvas.width) < 0.5
            && abs(piece.height - canvas.height) < 0.5
    }
}

enum PinnedScreenshotInteraction {
    static func shouldDismiss(clickCount: Int) -> Bool {
        clickCount >= 2
    }
}

/// Scroll-wheel zoom for a pinned screenshot. Callers pass the live window
/// frame and the pointer location; the rest (aspect, min/max, cursor anchor)
/// stays behind this interface.
enum PinnedScreenshotZoom {
    static let minLength: CGFloat = 48

    /// Trackpad inertia must not keep zooming after the fingers lift.
    static func shouldApply(isMomentum: Bool, deltaY: CGFloat) -> Bool {
        !isMomentum && deltaY != 0
    }

    /// Positive `deltaY` (scroll up) zooms in. Precise trackpad deltas are in
    /// points; mouse-wheel ticks are discrete steps.
    static func scaleFactor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        guard deltaY != 0 else { return 1 }
        if precise {
            return min(1.25, max(0.8, 1 + deltaY * 0.01))
        }
        let steps = min(max(deltaY, -4), 4)
        return pow(1.1, steps)
    }

    static func scaledFrame(
        current: CGRect,
        factor: CGFloat,
        anchorInWindow: CGPoint,
        minLength: CGFloat = minLength,
        maxSize: CGSize
    ) -> CGRect {
        let clamped = clampedFactor(
            current: current.size,
            proposed: factor,
            minLength: minLength,
            maxSize: maxSize
        )
        guard current.width > 0, current.height > 0, clamped > 0 else {
            return current
        }

        let newSize = CGSize(
            width: current.width * clamped,
            height: current.height * clamped
        )
        if abs(newSize.width - current.width) < 0.5,
           abs(newSize.height - current.height) < 0.5 {
            return current
        }

        let ratioX = anchorInWindow.x / current.width
        let ratioY = anchorInWindow.y / current.height
        return CGRect(
            x: current.origin.x + anchorInWindow.x - ratioX * newSize.width,
            y: current.origin.y + anchorInWindow.y - ratioY * newSize.height,
            width: newSize.width,
            height: newSize.height
        )
    }

    static func clampedFactor(
        current: CGSize,
        proposed: CGFloat,
        minLength: CGFloat,
        maxSize: CGSize
    ) -> CGFloat {
        guard current.width > 0, current.height > 0, proposed > 0 else {
            return 1
        }

        let minFactor = max(minLength / current.width, minLength / current.height)
        var maxFactor = CGFloat.greatestFiniteMagnitude
        if maxSize.width > 0 {
            maxFactor = min(maxFactor, maxSize.width / current.width)
        }
        if maxSize.height > 0 {
            maxFactor = min(maxFactor, maxSize.height / current.height)
        }
        if minFactor > maxFactor {
            return max(maxFactor, 0)
        }
        return min(max(proposed, minFactor), maxFactor)
    }
}

enum AppHotKey: Equatable {
    case ocr
    case pinnedScreenshot
}

enum HotKeyMatch {
    /// Carbon `kVK_ANSI_2` / `kVK_ANSI_3`.
    static let ocrKeyCode: Int64 = 0x13
    static let screenshotKeyCode: Int64 = 0x14

    static func match(
        keyCode: Int64,
        command: Bool,
        shift: Bool,
        control: Bool,
        option: Bool
    ) -> AppHotKey? {
        guard command, shift, !control, !option else {
            return nil
        }
        switch keyCode {
        case ocrKeyCode:
            return .ocr
        case screenshotKeyCode:
            return .pinnedScreenshot
        default:
            return nil
        }
    }
}
