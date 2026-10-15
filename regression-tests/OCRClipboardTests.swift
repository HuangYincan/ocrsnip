import AppKit
import CoreText

@MainActor
private final class TestPasteboard: OCRTextPasteboard {
    enum Response { case reject, mismatch, accept }
    var responses: [Response]
    var writes = 0
    var clears = 0
    var value: String?

    init(_ responses: [Response]) { self.responses = responses }

    func clearContents() -> Int {
        clears += 1
        value = nil
        return clears
    }

    func setString(_ string: String, forType _: NSPasteboard.PasteboardType) -> Bool {
        let response = responses[min(writes, responses.count - 1)]
        writes += 1
        switch response {
        case .reject: return false
        case .mismatch: value = "other clipboard owner"
        case .accept: value = string
        }
        return true
    }

    func string(forType _: NSPasteboard.PasteboardType) -> String? { value }
}

@main
private struct OCRClipboardTests {
    @MainActor
    static func main() async {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                failures += 1
            }
        }

        let cases: [([TestPasteboard.Response], Bool, Int)] = [
            ([TestPasteboard.Response.accept], true, 1),
            ([.reject, .accept], true, 2),
            ([.mismatch, .accept], true, 2),
            ([.reject, .reject, .accept], true, 3),
            ([.reject], false, 3),
            ([.mismatch], false, 3)
        ]
        for (responses, success, attempts) in cases {
            let pasteboard = TestPasteboard(responses)
            var delays = 0
            let result = await OCRClipboard.copyToPasteboard(
                "OCR text 中文\nsecond line",
                pasteboard: pasteboard,
                retryDelay: { delays += 1 }
            )
            expect(result == success, "copy result matches verified clipboard contents")
            expect(pasteboard.writes == attempts, "write attempts are bounded at three")
            expect(pasteboard.clears == attempts, "each attempt reacquires the pasteboard")
            expect(delays == attempts - 1, "wait only between failed attempts")
            if success {
                expect(pasteboard.value == "OCR text 中文\nsecond line", "preserve full Unicode text")
            }
        }

        let cancelledPasteboard = TestPasteboard([.reject, .accept])
        let cancelled = Task { @MainActor in
            await OCRClipboard.copyToPasteboard(
                "cancelled",
                pasteboard: cancelledPasteboard,
                retryDelay: { withUnsafeCurrentTask { $0?.cancel() } }
            )
        }
        let cancelledResult = await cancelled.value
        expect(!cancelledResult && cancelledPasteboard.writes == 1,
               "cancellation stops retries before clearing the clipboard again")

        if CommandLine.arguments.contains("--integration") {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let text = "OCRSNIP clipboard test 中文\n\(UUID().uuidString)"
            let copied = await OCRClipboard.copyToPasteboard(text, pasteboard: pasteboard)
            expect(copied && pasteboard.string(forType: .string) == text,
                   "real macOS pasteboard round trip")

            let context = CGContext(
                data: nil, width: 700, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 700, height: 140))
            context.textPosition = CGPoint(x: 20, y: 50)
            let line = NSAttributedString(string: "OCRSNIP 12345", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 48, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            let image = context.makeImage()!
            for run in 1...3 {
                let result = await Task.detached { OCRClipboard.recognize(image) }.value
                if case .text(let recognized) = result {
                    expect(recognized.contains("12345"), "Vision recognizes fixture on run \(run)")
                    let copied = await OCRClipboard.copyToPasteboard(recognized, pasteboard: pasteboard)
                    expect(copied && pasteboard.string(forType: .string) == recognized,
                           "Vision result reaches real pasteboard on run \(run)")
                } else {
                    expect(false, "Vision returned \(result) on run \(run)")
                }
            }
        }

        if failures > 0 { exit(1) }
        print("PASS: clipboard retry, readback, bounds and cancellation" +
              (CommandLine.arguments.contains("--integration") ? "; real pasteboard and initial/repeated Vision runs" : ""))
    }
}
