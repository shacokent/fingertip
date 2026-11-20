import Flutter
import UIKit
import Vision
import ImageIO

/// Uses the system's on-device hand model. The incoming image must already be
/// orientation-up, with EXIF rotation/mirroring baked into its pixels.
/// Joint order matches MediaPipe; Vision supplies 2D points only (z = 0).
final class OfflineHandLandmarkerPlugin: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "offline_nail.hand_landmarker", qos: .userInitiated)
  private let request: VNDetectHumanHandPoseRequest

  // wrist, thumb CMC/MCP/IP/TIP, then MCP/PIP/DIP/TIP for each remaining finger.
  private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
    .wrist,
    .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
    .indexMCP, .indexPIP, .indexDIP, .indexTip,
    .middleMCP, .middlePIP, .middleDIP, .middleTip,
    .ringMCP, .ringPIP, .ringDIP, .ringTip,
    .littleMCP, .littlePIP, .littleDIP, .littleTip
  ]

  override init() {
    request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2
    #if targetEnvironment(simulator)
    // Simulator has no Neural Engine. This selects a deterministic available backend.
    request.usesCPUOnly = true
    #endif
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "offline_nail/hand_landmarker", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(OfflineHandLandmarkerPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "detectImage" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "A canonical image file path is required.", details: nil))
      return
    }
    worker.async { [self] in
      autoreleasepool {
        do {
          guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
            throw NSError(domain: "OfflineNail", code: 1, userInfo: [NSLocalizedDescriptionKey: "The image cannot be decoded."])
          }
          let started = Date()
          let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
          try handler.perform([request])
          var hands: [[String: Any]] = []
          for observation in request.results ?? [] {
            let recognized = try observation.recognizedPoints(.all)
            let points = Self.jointOrder.compactMap { recognized[$0] }
            // Do not invent coordinates for missing/uncertain joints. Nail segmentation
            // can still proceed independently when a full hand is not available.
            guard points.count == 21, points.allSatisfy({ $0.confidence >= 0.1 }) else { continue }
            let handedness: String
            switch observation.chirality {
            case .left: handedness = "Left"
            case .right: handedness = "Right"
            default: handedness = "Unknown"
            }
            hands.append([
              "landmarks": points.map { point in
                [
                  "x": Double(point.location.x),
                  "y": Double(1.0 - point.location.y),
                  "z": 0.0,
                  "confidence": Double(point.confidence)
                ]
              },
              "handedness": handedness,
              "score": points.reduce(0.0) { $0 + Double($1.confidence) } / Double(points.count),
              "depthAvailable": false
            ])
          }
          let payload: [String: Any] = [
            "hands": hands,
            "width": cgImage.width,
            "height": cgImage.height,
            "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
            "backend": "Apple Vision (on-device)",
            "depthAvailable": false
          ]
          DispatchQueue.main.async { result(payload) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "HAND_DETECTION_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}
