from pathlib import Path
import subprocess
import sys

# Replay the production capture/recognition methods with screen selection,
# Vision and audio replaced. This checks completion timing without GUI access.
source = (Path(__file__).resolve().parent.parent / 'main.swift').read_text()
def method(name):
    marker = source.index('func ' + name + '(')
    start = source.rfind('\n', 0, marker) + 1
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func', 1)
code = r'''
import AppKit
import Foundation

enum OCRRecognizeResult { case text(String), empty, failed }
var copied = false
var prematureSound = false
var soundCount = 0
var recognitionResult = OCRRecognizeResult.text("recognized text")
var copySucceeds = true
var screenCaptureAllowed = true
func CGPreflightScreenCaptureAccess() -> Bool { screenCaptureAllowed }
enum ScreenCaptureStrategy {
    enum Backend { case nativeRegionSelection, legacyScreencaptureCLI }
    static var backend = Backend.nativeRegionSelection
    static func preferred() -> Backend { backend }
}
enum CaptureSound {
    static func playShutter() {
        soundCount += 1
        if !copied { prematureSound = true }
    }
}
enum ScreenRegionSelector {
    static func selectRegion() async -> CGRect? { CGRect(x: 0, y: 0, width: 100, height: 100) }
}
enum OCRClipboard {
    static func cgImage(from image: NSImage) -> CGImage? {
        CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()
    }
    static func recognize(_ image: CGImage) -> OCRRecognizeResult {
        Thread.sleep(forTimeInterval: 0.05)
        return recognitionResult
    }
    @MainActor static func copyToPasteboard(_ text: String) COPY_ASYNC -> Bool {
        copied = copySucceeds
        return copySucceeds
    }
}
@MainActor final class Replay: NSObject {
    final class Button { var title = "📷" }
    final class StatusItem { var button: Button? = Button() }
    var statusItem = StatusItem()
    var isRunningOCR = false
    var isCapturingRegion = false
    var captureCount = 0
    var permissionAlertCount = 0
    var appToRestoreAfterCapture: NSRunningApplication?
    func showScreenRecordingPermissionAlert() { permissionAlertCount += 1 }
    func captureWithLegacyScreencapture() async -> NSImage? {
        captureCount += 1
        return NSImage()
    }
    func restorePreviousApp() {}
    func captureDisplaySnapshots() async throws -> [CGImage] {
        captureCount += 1
        return [OCRClipboard.cgImage(from: NSImage())!]
    }
    func cropSnapshot(_ snapshots: [CGImage], cocoaRect: CGRect) -> CGImage? { snapshots.first }
    func sendNotification(title: String, body: String) {}
    static func screenCaptureErrorMessage(_ error: Error) -> String { error.localizedDescription }
'''
# Match the historical call signature so this replay can verify the old failure.
code = code.replace('COPY_ASYNC', 'async' if 'await OCRClipboard.copyToPasteboard' in source else '')
code += '\n'.join(method(name) for name in [
    'captureRegionImage', 'captureWithNativeRegionSelection', 'recognizeText', 'captureAndOCR'
]) + '\n}\n'
code += r'''
@main struct Test {
    @MainActor static func main() async {
        for backend in [ScreenCaptureStrategy.Backend.nativeRegionSelection, .legacyScreencaptureCLI] {
            ScreenCaptureStrategy.backend = backend
            screenCaptureAllowed = false
            let denied = Replay()
            let deniedImage = await denied.captureRegionImage()
            guard deniedImage == nil, denied.captureCount == 0, denied.permissionAlertCount == 1,
                  !denied.isCapturingRegion, denied.appToRestoreAfterCapture == nil else {
                print("FAIL: denied Screen Recording must show guidance and stop before capture; backend=\(backend), captureCount=\(denied.captureCount)")
                exit(1)
            }
            screenCaptureAllowed = true
            let allowed = Replay()
            let allowedImage = await allowed.captureRegionImage()
            guard allowedImage != nil, allowed.captureCount == 1, allowed.permissionAlertCount == 0,
                  !allowed.isCapturingRegion else {
                print("FAIL: granted Screen Recording must allow capture without a permission prompt")
                exit(1)
            }
        }
        ScreenCaptureStrategy.backend = .nativeRegionSelection
        print("PASS: denied Screen Recording blocks both backends; granted access captures without prompting")
        for (result, canCopy, expectedSounds) in [
            (OCRRecognizeResult.text("recognized text"), true, 1),
            (.text("recognized text"), false, 0),
            (.empty, true, 0),
            (.failed, true, 0)
        ] {
            copied = false
            prematureSound = false
            soundCount = 0
            recognitionResult = result
            copySucceeds = canCopy
            let replay = Replay()
            let image = await replay.captureWithNativeRegionSelection()!
            await replay.recognizeText(in: image)
            guard !prematureSound else {
                print("FAIL: shutter sounded before OCR text reached the clipboard")
                exit(1)
            }
            guard soundCount == expectedSounds else {
                print("FAIL: expected \(expectedSounds) completion sounds, received \(soundCount)")
                exit(1)
            }
        }
        copied = false
        prematureSound = false
        soundCount = 0
        recognitionResult = .text("recognized text")
        copySucceeds = true
        let replay = Replay()
        replay.captureAndOCR()
        replay.captureAndOCR()
        // Let both hotkey tasks start; the mock recognition takes 50ms.
        try? await Task.sleep(for: .milliseconds(10))
        guard replay.isRunningOCR, replay.statusItem.button?.title == "⏳" else {
            print("FAIL: OCR should remain busy while recognition is pending")
            exit(1)
        }
        for _ in 0..<200 {
            if !replay.isRunningOCR { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !replay.isRunningOCR, replay.captureCount == 1, soundCount == 1, !prematureSound,
              replay.statusItem.button?.title == "📷" else {
            print("FAIL: overlapping OCR triggers must not race or signal completion twice")
            exit(1)
        }
        print("PASS: capture stays silent until copy succeeds; empty/OCR/write failures stay silent")
        print("PASS: overlapping OCR triggers are ignored until completion; busy indicator resets")
    }
}
'''
work = Path(sys.argv[1])
path = work / 'Replay.swift'
path.write_text(code)
binary = work / 'replay'
subprocess.run(['swiftc', '-module-cache-path', sys.argv[2], '-parse-as-library', str(path), '-o', str(binary)], check=True)
raise SystemExit(subprocess.run([str(binary)]).returncode)
