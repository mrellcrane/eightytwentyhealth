import Foundation
import Vision

/// Reads the text in an image, on the phone. Nothing leaves the device.
enum ScreenshotReader {
    /// Async so callers stay off the main thread while Vision works.
    static func lines(in imageData: Data) async throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Numbers and units matter here, not words, and correction can "fix" them.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(data: imageData).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
