import Flutter
import Foundation
import UIKit
import Vision

public class MobileOcrPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "mobile_ocr", binaryMessenger: registrar.messenger())
        let instance = MobileOcrPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
        case "prepareModels":
            // iOS uses built-in Vision framework, no model download needed
            result([
                "isReady": true,
                "version": "iOS-Vision",
                "modelPath": "system"
            ])
        case "detectText":
            handleTextDetection(call: call, result: result)
        case "hasText":
            handleQuickTextCheck(call: call, result: result)
        case "ensureImageIsDisplayable":
            guard let arguments = call.arguments as? [String: Any],
                  let imagePath = arguments["imagePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Image path is required",
                                    details: nil))
                return
            }
            result(imagePath)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleTextDetection(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let imagePath = arguments["imagePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "Image path is required",
                               details: nil))
            return
        }

        let includeAllConfidenceScores = (arguments["includeAllConfidenceScores"] as? Bool) ?? false
        // Lower confidence thresholds to be more inclusive
        let minConfidence: Float = includeAllConfidenceScores ? 0.0 : 0.3

        detectTextInImage(imagePath: imagePath,
                         minConfidence: minConfidence,
                         result: result)
    }

    private func handleQuickTextCheck(call: FlutterMethodCall,
                                      result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let imagePath = arguments["imagePath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "Image path is required",
                               details: nil))
            return
        }

        // Use same threshold as detectText for consistency
        // Text validation will filter out false positives
        quickDetectText(imagePath: imagePath,
                        minConfidence: 0.3,
                        result: result)
    }

    private func detectTextInImage(imagePath: String,
                                  minConfidence: Float,
                                  result: @escaping FlutterResult) {
        // Move processing to background queue
        let workItem = DispatchWorkItem {
            let fileName = URL(fileURLWithPath: imagePath).lastPathComponent
            guard let image = UIImage(contentsOfFile: imagePath) else {
                MobileOcrPlugin.logDebug("detectText load failure for \(fileName)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to load image from path",
                                       details: nil))
                }
                return
            }

            // Fix image orientation using modern API
            var fixedImage = image
            var orientationFixed = false
            if image.imageOrientation != .up {
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = image.scale  // preserve original pixel density
                format.opaque = false
                let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
                fixedImage = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: image.size))
                }
                orientationFixed = true
            }

            guard let cgImage = fixedImage.cgImage else {
                MobileOcrPlugin.logDebug("detectText CGImage missing for \(fileName)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to get CGImage",
                                       details: nil))
                }
                return
            }

            let colorSpaceName = cgImage.colorSpace?.name as String? ?? "unknown"
            let originalSize = "\(Int(image.size.width))x\(Int(image.size.height))"
            let renderedSize = "\(cgImage.width)x\(cgImage.height)"
            MobileOcrPlugin.logDebug(
                "detectText start file=\(fileName) minConf=\(String(format: "%.2f", minConfidence))"
                + " originalOrient=\(image.imageOrientation.rawValue)"
                + " orientationFixed=\(orientationFixed)"
                + " size=\(originalSize) renderedSize=\(renderedSize)"
                + " colorSpace=\(colorSpaceName) bpc=\(cgImage.bitsPerComponent)"
            )

            // Create Vision request
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            var detectedTexts: [[String: Any]] = []
            var observationCount = 0
            var discardedLowConfidence = 0
            var previewSamples: [String] = []

            let request = VNRecognizeTextRequest { (request, error) in
                if let error = error {
                    print("Text recognition error: \(error.localizedDescription)")
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return
                }
                observationCount = observations.count

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }

                    // Filter by confidence
                    if topCandidate.confidence < minConfidence {
                        discardedLowConfidence += 1
                        continue
                    }

                    if previewSamples.count < 5 {
                        let sanitized = topCandidate.string
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        previewSamples.append(
                            "\(String(format: "%.2f", topCandidate.confidence))|\(sanitized)"
                        )
                    }

                    // Convert normalized coordinates to image coordinates
                    let imageWidth = CGFloat(cgImage.width)
                    let imageHeight = CGFloat(cgImage.height)

                    // VNRecognizedTextObservation inherits from VNRectangleObservation
                    // Use the actual corner points for accurate polygon representation
                    // Vision uses bottom-left origin, convert to top-left origin
                    let topLeft = CGPoint(
                        x: observation.topLeft.x * imageWidth,
                        y: (1 - observation.topLeft.y) * imageHeight
                    )
                    let topRight = CGPoint(
                        x: observation.topRight.x * imageWidth,
                        y: (1 - observation.topRight.y) * imageHeight
                    )
                    let bottomRight = CGPoint(
                        x: observation.bottomRight.x * imageWidth,
                        y: (1 - observation.bottomRight.y) * imageHeight
                    )
                    let bottomLeft = CGPoint(
                        x: observation.bottomLeft.x * imageWidth,
                        y: (1 - observation.bottomLeft.y) * imageHeight
                    )

                    // Create polygon points array
                    let points: [[String: Double]] = [
                        ["x": Double(topLeft.x), "y": Double(topLeft.y)],
                        ["x": Double(topRight.x), "y": Double(topRight.y)],
                        ["x": Double(bottomRight.x), "y": Double(bottomRight.y)],
                        ["x": Double(bottomLeft.x), "y": Double(bottomLeft.y)]
                    ]

                    // Character-level bounding boxes (iOS 16+ only)
                    let characterEntries: [[String: Any]] = []
                    // TODO: Re-enable when minimum iOS version is 16+
                    // Character boxes require iOS 16+ API that's not available in current build

                    detectedTexts.append([
                        "text": topCandidate.string,
                        "confidence": topCandidate.confidence,
                        "points": points,
                        "characters": characterEntries
                    ])
                }
            }

            // Configure request for best accuracy
            request.recognitionLevel = .accurate
            request.minimumTextHeight = 0.01
            request.usesLanguageCorrection = true

            // Use automatic language detection if available
            var configuredRevision = request.revision
            var autoLanguageEnabled = false
            if #available(iOS 16.0, *) {
                request.automaticallyDetectsLanguage = true
                autoLanguageEnabled = request.automaticallyDetectsLanguage
                request.revision = VNRecognizeTextRequestRevision3
                configuredRevision = request.revision
            } else {
                // Default to English for older iOS versions
                request.recognitionLanguages = ["en-US"]
            }
            MobileOcrPlugin.logDebug(
                "detectText request configured file=\(fileName)"
                + " revision=\(configuredRevision)"
                + " autoLanguage=\(autoLanguageEnabled)"
            )

            // Perform the request
            do {
                try requestHandler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "RECOGNITION_ERROR",
                                       message: "Failed to perform text recognition",
                                       details: error.localizedDescription))
                }
                return
            }
            MobileOcrPlugin.logDebug(
                "detectText finished file=\(fileName)"
                + " observations=\(observationCount)"
                + " kept=\(detectedTexts.count)"
                + " droppedLowConf=\(discardedLowConfidence)"
                + " samples=\(previewSamples.joined(separator: " | "))"
            )

            // Helper function to calculate bounding rect
            func boundingRect(for pointMaps: [[String: Double]]) -> CGRect? {
                guard let firstX = pointMaps.first?["x"], let firstY = pointMaps.first?["y"] else {
                    return nil
                }
                var minX = firstX, maxX = firstX, minY = firstY, maxY = firstY
                for point in pointMaps {
                    guard let x = point["x"], let y = point["y"] else { continue }
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
            }

            // Sort results by position (top to bottom, left to right)
            detectedTexts.sort { first, second in
                guard
                    let firstPoints = first["points"] as? [[String: Double]],
                    let secondPoints = second["points"] as? [[String: Double]],
                    let firstRect = boundingRect(for: firstPoints),
                    let secondRect = boundingRect(for: secondPoints)
                else {
                    return false
                }

                // Sort by vertical position, then horizontal
                if abs(firstRect.minY - secondRect.minY) > 10 {
                    return firstRect.minY < secondRect.minY
                }
                return firstRect.minX < secondRect.minX
            }

            // Return results on main thread
            DispatchQueue.main.async {
                result([
                    "blocks": detectedTexts,
                    "imageWidth": cgImage.width,
                    "imageHeight": cgImage.height
                ] as [String: Any])
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    // Helper to validate if text looks meaningful (not just symbols/noise)
    private func isValidText(_ text: String) -> Bool {
        // Remove whitespace and check length
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        let alphanumericSet = CharacterSet.alphanumerics

        // Look for at least one sequence of 3+ consecutive alphanumeric characters
        // This allows "198", "abc", "P@ss123" but rejects noise like "*•/• ; 41'4.•/4"
        var consecutiveCount = 0
        for scalar in trimmed.unicodeScalars {
            if alphanumericSet.contains(scalar) {
                consecutiveCount += 1
                if consecutiveCount >= 3 {
                    return true  // Found a word-like sequence
                }
            } else {
                consecutiveCount = 0
            }
        }

        return false
    }

    private func quickDetectText(imagePath: String,
                                 minConfidence: Float,
                                 result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async(execute: { [weak self] in
            guard let self = self else { return }
            let fileName = URL(fileURLWithPath: imagePath).lastPathComponent

            guard let image = UIImage(contentsOfFile: imagePath) else {
                MobileOcrPlugin.logDebug("hasText load failure for \(fileName)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to load image from path",
                                       details: nil))
                }
                return
            }

            // Downscale image for faster hasText detection
            // Use max dimension of 1024 pixels for quick detection
            let maxDimension: CGFloat = 1024
            var targetSize = image.size

            if image.size.width > maxDimension || image.size.height > maxDimension {
                let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
                targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            MobileOcrPlugin.logDebug(
                "hasText start file=\(fileName)"
                + " originalSize=\(Int(image.size.width))x\(Int(image.size.height))"
                + " scaledSize=\(Int(targetSize.width))x\(Int(targetSize.height))"
                + " minConf=\(String(format: "%.2f", minConfidence))"
            )

            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let fixedImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }

            guard let cgImage = fixedImage.cgImage else {
                MobileOcrPlugin.logDebug("hasText CGImage missing for \(fileName)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "IMAGE_LOAD_ERROR",
                                       message: "Failed to get CGImage",
                                       details: nil))
                }
                return
            }

            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            var hasValidText = false
            var observationCount = 0
            var acceptedCandidates = 0
            var rejectedByConfidence = 0
            var rejectedByValidation = 0
            var validationSamples: [String] = []

            // Use VNRecognizeTextRequest (same as detectText) instead of VNDetectTextRectanglesRequest
            // This ensures consistency between hasText and detectText
            let request = VNRecognizeTextRequest { (request, error) in
                if let error = error {
                    print("hasText - Text recognition error: \(error.localizedDescription)")
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return
                }
                observationCount = observations.count

                // Check if any recognized text meets the confidence threshold and is valid
                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }

                    let isValid = self.isValidText(topCandidate.string)

                    if topCandidate.confidence >= minConfidence {
                        if isValid {
                            acceptedCandidates += 1
                            hasValidText = true
                            if validationSamples.count < 3 {
                                let sanitized = topCandidate.string
                                    .replacingOccurrences(of: "\n", with: " ")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                validationSamples.append(
                                    "\(String(format: "%.2f", topCandidate.confidence))|\(sanitized)"
                                )
                            }
                            break  // Found at least one valid text with high confidence
                        } else {
                            rejectedByValidation += 1
                        }
                    } else {
                        rejectedByConfidence += 1
                    }
                }
            }

            // Use same settings as detectText for consistent confidence scores
            request.recognitionLevel = .accurate
            request.minimumTextHeight = 0.01
            request.usesLanguageCorrection = true

            // Use automatic language detection if available
            var configuredRevision = request.revision
            var autoLanguageEnabled = false
            if #available(iOS 16.0, *) {
                request.automaticallyDetectsLanguage = true
                autoLanguageEnabled = request.automaticallyDetectsLanguage
                request.revision = VNRecognizeTextRequestRevision3
                configuredRevision = request.revision
            } else {
                request.recognitionLanguages = ["en-US"]
            }
            MobileOcrPlugin.logDebug(
                "hasText request configured file=\(fileName)"
                + " revision=\(configuredRevision)"
                + " autoLanguage=\(autoLanguageEnabled)"
            )

            do {
                try requestHandler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DETECTION_ERROR",
                                       message: "Failed to perform text detection",
                                       details: error.localizedDescription))
                }
                return
            }
            MobileOcrPlugin.logDebug(
                "hasText finished file=\(fileName)"
                + " observations=\(observationCount)"
                + " validMatches=\(acceptedCandidates)"
                + " rejectedLowConf=\(rejectedByConfidence)"
                + " rejectedValidation=\(rejectedByValidation)"
                + " result=\(hasValidText)"
                + " samples=\(validationSamples.joined(separator: " | "))"
            )

            DispatchQueue.main.async {
                result(hasValidText)
            }
        })
    }

    private static func logDebug(_ message: String) {
        #if DEBUG
        print("[MobileOCR] \(message)")
        #endif
    }

}
