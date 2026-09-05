import AppKit
import Vision

enum OCRRecognizeResult: Equatable, Sendable {
    case text(String)
    case empty
    case failed
}

enum OCRClipboard {
    static func cgImage(from image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return sRGB8(cgImage)
        }
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let cgImage = bitmap.cgImage {
            return sRGB8(cgImage)
        }
        return nil
    }

    static func recognize(_ cgImage: CGImage) -> OCRRecognizeResult {
        let prepared = sRGB8(cgImage)
        var recognizedEmpty = false
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            do {
                let text = try runVision(prepared, level: level)
                if !text.isEmpty {
                    return .text(text)
                }
                recognizedEmpty = true
            } catch {
                continue
            }
        }
        return recognizedEmpty ? .empty : .failed
    }

    @discardableResult
    static func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func isAlreadySRGB8(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32 else {
            return false
        }
        switch image.alphaInfo {
        case .premultipliedLast, .last, .noneSkipLast:
            break
        default:
            return false
        }
        guard let colorSpace = image.colorSpace, let name = colorSpace.name else {
            return false
        }
        return name == CGColorSpace.sRGB || name == CGColorSpace.extendedSRGB
    }

    static func sRGB8(_ image: CGImage) -> CGImage {
        if isAlreadySRGB8(image) {
            return image
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func runVision(
        _ cgImage: CGImage,
        level: VNRequestTextRecognitionLevel
    ) throws -> String {
        var text = ""
        var requestError: Error?
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                requestError = error
                return
            }
            text = request.results?
                .compactMap { $0 as? VNRecognizedTextObservation }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
        }
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let requestError {
            throw requestError
        }
        return text
    }
}
