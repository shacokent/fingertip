import AVFoundation
import CoreImage
import Flutter
import ImageIO
import UIKit
import Vision

/// On-device Vision and camera ownership. The makeup stream uses upright
/// unreflected landmarks. Viewfinder and JPEG reflection are independent.
final class OfflineBeautyPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  AVCaptureVideoDataOutputSampleBufferDelegate {
  private let worker = DispatchQueue(label: "yuying.beauty.camera", qos: .userInitiated)
  private let tokenLock = NSLock()
  private var token: UInt64 = 0
  private var eventSink: FlutterEventSink?
  private var backgroundObserver: NSObjectProtocol?
  private weak var preview: BeautyPreviewView?
  // This reference is used only on the main thread to attach newly created views.
  private var displayedSession: AVCaptureSession?
  private var displayedPhoto: (sessionId: Int, lens: AVCaptureDevice.Position)?
  private var mirrorPreview = true

  // The following state is confined to worker, including capture delegates.
  private var captureSession: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var photoOutput: AVCapturePhotoOutput?
  private var stillDelegates: [Int64: BeautyStillPhotoDelegate] = [:]
  private var activeToken: UInt64 = 0
  private var activeSessionId = 0
  private var activeMakeup = false
  private var latestBuffer: CVPixelBuffer?
  private var latestTimestampMs: Int64 = 0
  private var lastAnalysisTime: TimeInterval = 0
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let faceRequest = VNDetectFaceLandmarksRequest()
  private let maxMakeupFrameAgeMs: Int64 = 240

  override init() {
    super.init()
    #if targetEnvironment(simulator)
    faceRequest.usesCPUOnly = true
    #endif
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.stop(result: nil) }
  }

  deinit {
    if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = OfflineBeautyPlugin()
    let methods = FlutterMethodChannel(name: "yuying/beauty", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: methods)
    FlutterEventChannel(name: "yuying/beauty_events", binaryMessenger: registrar.messenger())
      .setStreamHandler(plugin)
    registrar.register(BeautyPreviewFactory(plugin: plugin), withId: "yuying/beauty_preview")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      start(sessionId: (args["sessionId"] as? NSNumber)?.intValue ?? 0, result: result)
    case "startPhoto", "startMakeup":
      let lens: AVCaptureDevice.Position = args["lens"] as? String == "rear" ? .back : .front
      let requestedMirror = args["mirrored"] as? Bool ?? (lens == .front ? args["followsSelf"] as? Bool : nil)
      start(sessionId: (args["sessionId"] as? NSNumber)?.intValue ?? 0, photoLens: lens,
            requestedMirror: requestedMirror, tracksMakeup: call.method == "startMakeup", result: result)
    case "stop", "dispose":
      stop(result: result)
    case "capture":
      capture(result: result)
    case "capturePhoto":
      capturePhoto(sessionId: (args["sessionId"] as? NSNumber)?.intValue, result: result)
    case "setPhotoPreviewDirection":
      setPhotoPreviewDirection(args: args, result: result)
    case "focusPhoto":
      focusPhoto(args: args, result: result)
    case "analyzeImage":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "图片路径无效。", details: nil))
        return
      }
      analyzeImage(path: path, includeMakeup: args["includeMakeup"] as? Bool == true, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func nextToken() -> UInt64 {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    token &+= 1
    return token
  }

  private func isCurrent(_ expected: UInt64) -> Bool {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    return token == expected
  }

  private func emit(_ event: [String: Any], token expected: UInt64) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.isCurrent(expected) else { return }
      var delivered = event
      if event["type"] as? String == "frame", let photo = self.displayedPhoto,
         event["sessionId"] as? Int == photo.sessionId {
        delivered["mirrored"] = self.mirrorPreview
        if let timestamp = event["timestampMs"] as? Int64,
           Int64(ProcessInfo.processInfo.systemUptime * 1000) - timestamp > self.maxMakeupFrameAgeMs {
          delivered["face"] = NSNull()
          delivered["faceCount"] = 0
          delivered.removeValue(forKey: "makeupRegions")
          delivered.removeValue(forKey: "skinSample")
        }
      }
      self.eventSink?(delivered)
    }
  }

  private func status(_ status: String, sessionId: Int, token: UInt64, message: String? = nil) {
    var payload: [String: Any] = ["type": "status", "sessionId": sessionId, "status": status]
    if let message = message { payload["message"] = message }
    emit(payload, token: token)
  }

  private func photoPreviewPreferenceKey(_ lens: AVCaptureDevice.Position) -> String {
    lens == .front ? "beauty.photoPreview.frontMirrored" : "beauty.photoPreview.rearMirrored"
  }

  private func start(sessionId: Int, photoLens: AVCaptureDevice.Position? = nil, requestedMirror: Bool? = nil,
                     tracksMakeup: Bool = false, result: @escaping FlutterResult) {
    let expected = nextToken()
    let mirrors = photoLens.map { lens in
      requestedMirror ??
        (UserDefaults.standard.object(forKey: photoPreviewPreferenceKey(lens)) as? Bool) ??
        (lens == .front)
    } ?? true
    status("starting", sessionId: sessionId, token: expected)
    let authorized: (Bool) -> Void = { [weak self] allowed in
      guard let self = self else { return }
      guard self.isCurrent(expected) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "CANCELLED", message: "相机启动已取消。", details: nil))
        }
        return
      }
      guard allowed else {
        self.status("cameraDenied", sessionId: sessionId, token: expected,
                    message: "请在系统设置中允许煜莹使用相机。")
        DispatchQueue.main.async {
          result(FlutterError(code: "CAMERA_DENIED", message: "未获得相机权限。", details: nil))
        }
        return
      }
      self.worker.async { [self] in
        guard self.isCurrent(expected) else {
          DispatchQueue.main.async {
            result(FlutterError(code: "CANCELLED", message: "相机启动已取消。", details: nil))
          }
          return
        }
        self.tearDownSession()
        do {
          let session: AVCaptureSession
          if let lens = photoLens { session = try self.makePhotoSession(lens: lens, tracksMakeup: tracksMakeup) }
          else { session = try self.makeSession() }
          guard self.isCurrent(expected) else {
            DispatchQueue.main.async {
              result(FlutterError(code: "CANCELLED", message: "相机启动已取消。", details: nil))
            }
            return
          }
          self.captureSession = session
          self.activeToken = expected
          self.activeSessionId = sessionId
          self.activeMakeup = tracksMakeup
          self.latestBuffer = nil
          self.lastAnalysisTime = 0
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCurrent(expected) else { return }
            self.displayedSession = session
            self.displayedPhoto = photoLens.map { (sessionId, $0) }
            self.mirrorPreview = mirrors
            self.attachSession(session, to: self.preview)
          }
          session.startRunning()
          guard self.isCurrent(expected) else {
            self.tearDownSession()
            DispatchQueue.main.async {
              result(FlutterError(code: "CANCELLED", message: "相机启动已取消。", details: nil))
            }
            return
          }
          guard session.isRunning else {
            throw BeautyError.camera("所选相机暂时无法打开，可切换镜头后重试。")
          }
          self.status("ready", sessionId: sessionId, token: expected)
          DispatchQueue.main.async { [self] in
            guard self.isCurrent(expected) else {
              result(FlutterError(code: "CANCELLED", message: "相机启动已取消。", details: nil))
              return
            }
            // The running session has its preview connection even if it was
            // unavailable at the time the view was first attached.
            let appliedMirror = self.preview?.setMirrored(mirrors) ?? mirrors
            self.mirrorPreview = appliedMirror
            result(["width": 480, "height": 640, "mirrored": appliedMirror])
          }
        } catch {
          self.tearDownSession()
          self.status("error", sessionId: sessionId, token: expected, message: error.localizedDescription)
          DispatchQueue.main.async {
            result(FlutterError(code: "CAMERA_START_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: authorized(true)
    case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: authorized)
    default: authorized(false)
    }
  }

  private func makeSession() throws -> AVCaptureSession {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
      throw BeautyError.camera("当前设备没有可用的前置相机。请使用连接的 iPhone 体验自拍试戴。")
    }
    let session = AVCaptureSession()
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw BeautyError.camera("前置相机暂不可用。") }
    session.addInput(input)

    // Keep the full frame at 4:3 so the shared preview/overlay coordinate system
    // does not silently crop a different region on one platform.
    let candidates = device.formats.filter { format in
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let ratio = Double(dimensions.width) / Double(dimensions.height)
      return dimensions.width >= 640 && dimensions.width <= 1280 && dimensions.height <= 960
        && abs(ratio - 4.0 / 3.0) < 0.02
        && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 24 && $0.maxFrameRate >= 24 }
    }
    let format = candidates.max { a, b in
      let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
      let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
      return da.width * da.height < db.width * db.height
    }
    if let format = format, session.canSetSessionPreset(.inputPriority) {
      session.sessionPreset = .inputPriority
      try device.lockForConfiguration()
      device.activeFormat = format
      device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
      device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
      if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
      device.unlockForConfiguration()
    } else if session.canSetSessionPreset(.vga640x480) {
      session.sessionPreset = .vga640x480
    }
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: worker)
    guard session.canAddOutput(output) else { throw BeautyError.camera("无法读取自拍预览。") }
    session.addOutput(output)
    if let connection = output.connection(with: .video) {
      if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
      }
    }
    videoOutput = output
    return session
  }

  private func makePhotoSession(lens: AVCaptureDevice.Position, tracksMakeup: Bool) throws -> AVCaptureSession {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens) else {
      throw BeautyError.camera("所选镜头不可用，可切换镜头后重试。")
    }
    let session = AVCaptureSession()
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCapturePhotoOutput()
    guard session.canAddInput(input) else { throw BeautyError.camera("所选镜头不可用。") }
    session.addInput(input)
    guard session.canAddOutput(output) else { throw BeautyError.camera("相机无法拍摄照片。") }
    session.addOutput(output)
    if tracksMakeup {
      let analysis = AVCaptureVideoDataOutput()
      analysis.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      // A photo session can deliver preview-sized buffers without reducing
      // the resolution of its independent still output.
      analysis.automaticallyConfiguresOutputBufferDimensions = true
      analysis.alwaysDiscardsLateVideoFrames = true
      guard session.canAddOutput(analysis) else { throw BeautyError.camera("所选镜头无法实时试妆。") }
      session.addOutput(analysis)
      if let connection = analysis.connection(with: .video) {
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
          connection.automaticallyAdjustsVideoMirroring = false
          connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
      }
      analysis.setSampleBufferDelegate(self, queue: worker)
      videoOutput = analysis
    }
    photoOutput = output
    return session
  }

  private func tearDownSession() {
    let old = captureSession
    if let old = old {
      if old.isRunning { old.stopRunning() }
      videoOutput?.setSampleBufferDelegate(nil, queue: nil)
      old.beginConfiguration()
      old.inputs.forEach { old.removeInput($0) }
      old.outputs.forEach { old.removeOutput($0) }
      old.commitConfiguration()
    }
    captureSession = nil
    videoOutput = nil
    photoOutput = nil
    activeMakeup = false
    latestBuffer = nil
    latestTimestampMs = 0
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.displayedSession === old {
        self.displayedSession = nil
        self.displayedPhoto = nil
        self.preview?.previewLayer.session = nil
      }
    }
  }

  private func stop(result: FlutterResult?) {
    _ = nextToken() // Invalidate queued frame/status delivery and permission callbacks immediately.
    worker.async { [self] in
      tearDownSession()
      if let result = result { DispatchQueue.main.async { result(nil) } }
    }
  }

  fileprivate func attachPreview(_ view: BeautyPreviewView) {
    preview = view
    attachSession(displayedSession, to: view)
  }

  fileprivate func detachPreview(_ view: BeautyPreviewView) {
    guard preview === view else { return }
    preview = nil
    stop(result: nil)
  }

  private func attachSession(_ session: AVCaptureSession?, to view: BeautyPreviewView?) {
    guard let view = view else { return }
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspect
    if let connection = view.previewLayer.connection {
      if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
      if displayedPhoto != nil && connection.isVideoStabilizationSupported {
        connection.preferredVideoStabilizationMode = .off
      }
    }
    _ = view.setMirrored(mirrorPreview)
  }

  private func setPhotoPreviewDirection(args: [String: Any], result: FlutterResult) {
    guard let sessionId = (args["sessionId"] as? NSNumber)?.intValue,
          let photo = displayedPhoto, sessionId == photo.sessionId,
          let requested = args["mirrored"] as? Bool ?? args["followsSelf"] as? Bool,
          let applied = preview?.setMirrored(requested) else {
      result(FlutterError(code: "CAMERA_NOT_READY", message: "相机尚未准备好。", details: nil))
      return
    }
    mirrorPreview = applied
    UserDefaults.standard.set(applied, forKey: photoPreviewPreferenceKey(photo.lens))
    result(applied)
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard isCurrent(activeToken), output === videoOutput, captureSession?.isRunning == true,
          let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    latestTimestampMs = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    if !activeMakeup { latestBuffer = buffer }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastAnalysisTime >= 0.065 else { return }
    lastAnalysisTime = now
    let expected = activeToken
    autoreleasepool {
      do {
        // Legacy video captures keep their reflected coordinates. In makeup
        // mode Vision works in the same unreflected space as the saved still.
        let orientation: CGImagePropertyOrientation =
          activeMakeup && connection.isVideoMirrored ? .upMirrored : .up
        let result = try faceGeometry(
          handler: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:]),
          width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), includeMakeup: activeMakeup)
        var event: [String: Any] = [
          "type": "frame", "sessionId": activeSessionId, "timestampMs": latestTimestampMs,
          "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
          "face": result.face ?? NSNull(), "faceCount": result.count
        ]
        if let makeup = result.makeup, let face = result.face {
          event["makeupRegions"] = makeup
          if let sample = videoSkinSample(buffer, face: face, regions: makeup,
                                         reflectedBuffer: connection.isVideoMirrored) {
            event["skinSample"] = sample
          }
        }
        if result.count > 1 { event["message"] = "请让画面中只保留一张人脸。" }
        emit(event, token: expected)
      } catch {
        emit(["type": "frame", "sessionId": activeSessionId, "timestampMs": latestTimestampMs,
              "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
              "face": NSNull(), "faceCount": 0, "message": "暂未识别到清晰人脸。"], token: expected)
      }
    }
  }

  private func faceGeometry(
    handler: VNImageRequestHandler, width: Int, height: Int, includeMakeup: Bool = false
  ) throws -> (face: [String: Any]?, count: Int, makeup: [String: [[Double]]]?) {
    try handler.perform([faceRequest])
    let observations = (faceRequest.results ?? []).filter { $0.confidence >= 0.55 }
    guard observations.count == 1, let face = observations.first else {
      return (nil, observations.count, nil)
    }
    let box = face.boundingBox
    guard box.width > 0.04, box.height > 0.06 else { return (nil, 0, nil) }
    let makeup = includeMakeup ? makeupRegions(face) : nil
    func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
      guard let region = region, region.pointCount > 0 else { return nil }
      let points = region.normalizedPoints
      let x = points.reduce(CGFloat(0)) { $0 + CGFloat($1.x) } / CGFloat(region.pointCount)
      let y = points.reduce(CGFloat(0)) { $0 + CGFloat($1.y) } / CGFloat(region.pointCount)
      return CGPoint(x: box.minX + x * box.width, y: 1 - (box.minY + y * box.height))
    }
    var payload: [String: Any] = [
      "cx": Double(box.midX), "cy": Double(1 - box.midY),
      "width": Double(box.width) * 0.84, "height": Double(box.height),
      "score": Double(face.confidence),
      "rawBounds": ["cx": Double(box.midX), "cy": Double(1 - box.midY),
                    "width": Double(box.width), "height": Double(box.height)]
    ]
    if let eye1 = center(face.landmarks?.leftEye), let eye2 = center(face.landmarks?.rightEye) {
      let left = eye1.x < eye2.x ? eye1 : eye2
      let right = eye1.x < eye2.x ? eye2 : eye1
      let dx = (right.x - left.x) * CGFloat(width)
      let dy = (right.y - left.y) * CGFloat(height)
      let eyeDistance = hypot(dx, dy)
      let ratio = eyeDistance / (box.width * CGFloat(width))
      // A bad landmark result must not turn a clear frontal face sideways. Some
      // simulator Vision backends return an implausibly collapsed eye region.
      // Use only geometrically valid observations; never synthesize eye points.
      if ratio >= 0.20 && ratio <= 0.75 && eyeDistance > 5 {
        let roll = atan2(dy, dx)
        let eyeMid = CGPoint(x: (left.x + right.x) * 0.5, y: (left.y + right.y) * 0.5)
        var yaw = -(face.yaw?.doubleValue ?? 0)
        if let nose = center(face.landmarks?.noseCrest) ?? center(face.landmarks?.nose) {
          let nx = (nose.x - eyeMid.x) * CGFloat(width)
          let ny = (nose.y - eyeMid.y) * CGFloat(height)
          let displacement = nx * cos(roll) + ny * sin(roll)
          yaw = Double(atan2(displacement, eyeDistance * 0.8))
        }
        // Match the fitting width used by the shared Android eye anchors. This
        // is a calibrated hairstyle fitting box; raw detector bounds remain
        // separately available above and no landmark coordinates are invented.
        payload["width"] = Double(eyeDistance * 2.32 / CGFloat(width))
        payload["roll"] = Double(roll)
        payload["yaw"] = max(-1.2, min(1.2, yaw))
        payload["leftEyeX"] = Double(left.x)
        payload["leftEyeY"] = Double(left.y)
        payload["rightEyeX"] = Double(right.x)
        payload["rightEyeY"] = Double(right.y)
        payload["geometrySource"] = "visionLandmarks"
        return (payload, 1, makeup)
      }
    }
    // VNFaceObservation also exposes angles from the face detector itself.
    // They are real observations, not a centered-face template. When detailed
    // landmarks are unreliable, omit them and preserve this measured pose.
    guard let observedRoll = face.roll?.doubleValue, let observedYaw = face.yaw?.doubleValue,
          observedRoll.isFinite, observedYaw.isFinite else { return (nil, 1, makeup) }
    payload["roll"] = -observedRoll
    payload["yaw"] = -observedYaw
    payload["geometrySource"] = "visionFacePose"
    return (payload, 1, makeup)
  }

  private func makeupRegions(_ face: VNFaceObservation) -> [String: [[Double]]]? {
    guard let landmarks = face.landmarks else { return nil }
    let box = face.boundingBox
    let regions: [String: VNFaceLandmarkRegion2D?] = [
      "outline": landmarks.faceContour,
      "eyeA": landmarks.leftEye,
      "eyeB": landmarks.rightEye,
      "browA": landmarks.leftEyebrow,
      "browB": landmarks.rightEyebrow,
      "outerLips": landmarks.outerLips,
      "innerLips": landmarks.innerLips,
      "nose": landmarks.nose
    ]
    // Vision landmarks are face-relative with a lower-left origin. Convert
    // them to image-relative coordinates with the origin at the top left.
    return regions.mapValues { region in
      region?.normalizedPoints.map { point in
        [Double(box.minX + point.x * box.width), Double(1 - (box.minY + point.y * box.height))]
      } ?? []
    }
  }

  private struct CheekSample {
    let red: Double, green: Double, blue: Double, luma: Double, quality: Double
  }

  /// Read only small cheek patches while the existing camera buffer is locked.
  private func videoSkinSample(
    _ buffer: CVPixelBuffer, face: [String: Any], regions: [String: [[Double]]],
    reflectedBuffer: Bool
  ) -> [String: Double]? {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
          CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    return skinSample(width: width, height: height, face: face, regions: regions) { x, y in
      let offset = y * stride + (reflectedBuffer ? width - 1 - x : x) * 4
      return (bytes[offset + 2], bytes[offset + 1], bytes[offset])
    }
  }

  private func stillSkinSample(
    _ image: CGImage, face: [String: Any], regions: [String: [[Double]]]
  ) -> [String: Double]? {
    // Explicitly bounded color sampling for a decoded still, never its full
    // resolution. Use sRGB, and the same patch locations as the viewfinder.
    let factor = min(1, 160.0 / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * factor))
    let height = max(1, Int(Double(image.height) * factor))
    let stride = width * 4
    var bytes = [UInt8](repeating: 0, count: stride * height)
    return bytes.withUnsafeMutableBytes { storage in
      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
              data: storage.baseAddress, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: stride, space: colorSpace,
              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return nil }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return skinSample(width: width, height: height, face: face, regions: regions) { x, y in
        let offset = y * stride + x * 4
        return (storage[offset + 2], storage[offset + 1], storage[offset])
      }
    }
  }

  private func skinSample(
    width: Int, height: Int, face: [String: Any], regions: [String: [[Double]]],
    pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
  ) -> [String: Double]? {
    guard let yaw = face["yaw"] as? Double, abs(yaw) <= 0.46,
          let leftX = face["leftEyeX"] as? Double, let leftY = face["leftEyeY"] as? Double,
          let rightX = face["rightEyeX"] as? Double, let rightY = face["rightEyeY"] as? Double else { return nil }
    let inner = regions["innerLips"] ?? []
    let lips = inner.isEmpty ? (regions["outerLips"] ?? []) : inner
    guard !lips.isEmpty else { return nil }
    let w = Double(width), h = Double(height)
    let lx = leftX * w, ly = leftY * h, rx = rightX * w, ry = rightY * h
    let ex = rx - lx, ey = ry - ly, span = hypot(ex, ey)
    guard span.isFinite, span >= max(4, w * 0.035) else { return nil }
    let count = Double(lips.count)
    let mx = lips.reduce(0.0) { $0 + $1[0] } / count * w
    let my = lips.reduce(0.0) { $0 + $1[1] } / count * h
    let depth = ((mx - (lx + rx) * 0.5) * -ey + (my - (ly + ry) * 0.5) * ex)
      / (span * span) * 0.52
    guard depth.isFinite, (0.23...0.78).contains(depth) else { return nil }

    func cheek(_ x: Double, _ y: Double, _ side: Double) -> CheekSample? {
      var red = [Double](), green = [Double](), blue = [Double](), luma = [Double]()
      for row in -1...1 {
        for column in -1...1 {
          let horizontal = side * 0.12 + Double(column) * 0.07
          let vertical = depth + Double(row) * 0.065
          let px = Int(x + ex * horizontal - ey * vertical)
          let py = Int(y + ey * horizontal + ex * vertical)
          guard (0..<width).contains(px), (0..<height).contains(py) else { continue }
          let color = pixel(px, py)
          let r = Double(color.0) / 255, g = Double(color.1) / 255, b = Double(color.2) / 255
          let value = 0.2126 * r + 0.7152 * g + 0.0722 * b
          guard (0.075...0.94).contains(value), max(r, g, b) < 0.995 else { continue }
          red.append(r); green.append(g); blue.append(b); luma.append(value)
        }
      }
      let n = luma.count
      guard n >= 7 else { return nil }
      red.sort(); green.sort(); blue.sort(); luma.sort()
      let spread = luma[n * 3 / 4] - luma[n / 4]
      let exposure = min(1, max(0, (luma[n / 2] - 0.075) / 0.14))
      let quality = max(0, 1 - spread / 0.22) * Double(n) / 9 * exposure
      return CheekSample(red: red[n / 2], green: green[n / 2], blue: blue[n / 2],
                         luma: luma[n / 2], quality: quality)
    }
    guard let left = cheek(lx, ly, -1), let right = cheek(rx, ry, 1) else { return nil }
    let confidence = min(left.quality, right.quality) * max(0, 1 - abs(left.luma - right.luma) / 0.42)
    guard confidence >= 0.18 else { return nil }
    return ["r": (left.red + right.red) * 0.5, "g": (left.green + right.green) * 0.5,
            "b": (left.blue + right.blue) * 0.5, "confidence": confidence]
  }

  private func capture(result: @escaping FlutterResult) {
    tokenLock.lock()
    let expected = token
    tokenLock.unlock()
    worker.async { [self] in
      autoreleasepool {
        guard self.isCurrent(expected), self.captureSession?.isRunning == true,
              let buffer = self.latestBuffer,
              Int64(ProcessInfo.processInfo.systemUptime * 1000) - self.latestTimestampMs < 1000 else {
          DispatchQueue.main.async {
            result(FlutterError(code: "CAMERA_NOT_READY", message: "相机尚未准备好，请稍后再拍。", details: nil))
          }
          return
        }
        do {
          let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
          let analysis = try self.faceGeometry(
            handler: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]),
            width: width, height: height)
          let image = CIImage(cvPixelBuffer: buffer)
          guard let cgImage = self.ciContext.createCGImage(image, from: image.extent),
                let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.96) else {
            throw BeautyError.camera("自拍照片无法编码，请重试。")
          }
          let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YuyingBeauty", isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let file = folder.appendingPathComponent("beauty_capture_\(UUID().uuidString).jpg")
          try jpeg.write(to: file, options: .atomic)
          guard self.isCurrent(expected) else {
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
              result(FlutterError(code: "CANCELLED", message: "拍照已取消。", details: nil))
            }
            return
          }
          let payload: [String: Any] = [
            "path": file.path, "width": width, "height": height,
            "face": analysis.face ?? NSNull(), "faceCount": analysis.count, "mirrored": true
          ]
          DispatchQueue.main.async { result(payload) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  private func capturePhoto(sessionId: Int?, result: @escaping FlutterResult) {
    worker.async { [self] in
      let expected = activeToken
      guard isCurrent(expected), activeSessionId == sessionId, captureSession?.isRunning == true,
            let output = photoOutput, let connection = output.connection(with: .video),
            output.availablePhotoCodecTypes.contains(.jpeg) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "CAMERA_NOT_READY", message: "相机尚未准备好，请稍后再拍。", details: nil))
        }
        return
      }
      if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
      // The viewfinder and the photograph use separate connections. Disable
      // automatic reflection here so AVFoundation does not tag a mirrored JPEG.
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
      }
      let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
      let id = settings.uniqueID
      let delegate = BeautyStillPhotoDelegate { [self] outcome in
        worker.async { [self] in
          stillDelegates.removeValue(forKey: id)
          do {
            guard isCurrent(expected) else { throw BeautyError.camera("拍照已取消。") }
            let data = try outcome.get()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YuyingBeauty", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("beauty_photo_\(UUID().uuidString).jpg")
            try data.write(to: file, options: .atomic)
            DispatchQueue.main.async { [self] in
              if isCurrent(expected) { result(file.path) }
              else {
                try? FileManager.default.removeItem(at: file)
                result(FlutterError(code: "CAPTURE_CANCELLED", message: "拍照已取消。", details: nil))
              }
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "CAPTURE_FAILED", message: "拍照失败，可切换镜头后重试。", details: nil))
            }
          }
        }
      }
      stillDelegates[id] = delegate
      output.capturePhoto(with: settings, delegate: delegate)
    }
  }

  private func focusPhoto(args: [String: Any], result: @escaping FlutterResult) {
    guard let view = preview,
          let x = (args["x"] as? NSNumber)?.doubleValue, (0...1).contains(x),
          let y = (args["y"] as? NSNumber)?.doubleValue, (0...1).contains(y) else {
      result(nil)
      return
    }
    let point = view.devicePoint(x: x, y: y)
    let sessionId = (args["sessionId"] as? NSNumber)?.intValue
    worker.async { [self] in
      guard isCurrent(activeToken), sessionId == activeSessionId, photoOutput != nil,
            let device = (captureSession?.inputs.first as? AVCaptureDeviceInput)?.device,
            (0...1).contains(point.x), (0...1).contains(point.y) else { return }
      guard (try? device.lockForConfiguration()) != nil else { return }
      defer { device.unlockForConfiguration() }
      if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
        device.focusPointOfInterest = point
        device.focusMode = .autoFocus
      }
      if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposurePointOfInterest = point
        device.exposureMode = .continuousAutoExposure
      }
    }
    result(nil)
  }

  private func analyzeImage(path: String, includeMakeup: Bool, result: @escaping FlutterResult) {
    worker.async { [self] in
      autoreleasepool {
        do {
          guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BeautyError.camera("图片无法读取。")
          }
          let started = ProcessInfo.processInfo.systemUptime
          let analysis = try self.faceGeometry(
            handler: VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]),
            width: image.width, height: image.height, includeMakeup: includeMakeup)
          var payload: [String: Any] = [
            "width": image.width, "height": image.height, "face": analysis.face ?? NSNull(),
            "faceCount": analysis.count, "backend": "Apple Vision (on-device)",
            "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
          ]
          if let makeup = analysis.makeup {
            payload["makeupRegions"] = makeup
            if let face = analysis.face, let sample = stillSkinSample(image, face: face, regions: makeup) {
              payload["skinSample"] = sample
            }
          }
          let output = payload
          DispatchQueue.main.async { result(output) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "FACE_DETECTION_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}

private final class BeautyStillPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let completion: (Result<Data, Error>) -> Void
  private var processed: Result<Data, Error>?

  init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                   error: Error?) {
    if let error = error { processed = .failure(error) }
    else if let data = photo.fileDataRepresentation() { processed = .success(data) }
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                   error: Error?) {
    if let error = error { completion(.failure(error)) }
    else { completion(processed ?? .failure(BeautyError.camera("照片无法读取。"))) }
  }
}

private enum BeautyError: LocalizedError {
  case camera(String)
  var errorDescription: String? {
    switch self { case .camera(let message): return message }
  }
}

private final class BeautyPreviewView: UIView {
  let previewLayer = AVCaptureVideoPreviewLayer()
  private var extraReflection = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    previewLayer.videoGravity = .resizeAspect
    previewLayer.frame = bounds
    layer.addSublayer(previewLayer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
    previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
  }

  func setMirrored(_ mirrored: Bool) -> Bool? {
    guard let connection = previewLayer.connection else { return nil }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = mirrored
    }
    // If a connection cannot mirror in hardware, reflect only the child
    // layer. The platform view and photo connection stay independent.
    extraReflection = connection.isVideoMirrored != mirrored
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    previewLayer.setAffineTransform(CGAffineTransform(scaleX: extraReflection ? -1 : 1, y: 1))
    CATransaction.commit()
    return connection.isVideoMirrored != extraReflection
  }

  func devicePoint(x: Double, y: Double) -> CGPoint {
    let layerX = extraReflection ? 1 - x : x
    return previewLayer.captureDevicePointConverted(fromLayerPoint:
      CGPoint(x: layerX * previewLayer.bounds.width, y: y * previewLayer.bounds.height))
  }
}

private final class BeautyPlatformView: NSObject, FlutterPlatformView {
  private let nativeView: BeautyPreviewView
  private weak var plugin: OfflineBeautyPlugin?
  init(frame: CGRect, plugin: OfflineBeautyPlugin) {
    nativeView = BeautyPreviewView(frame: frame)
    self.plugin = plugin
    super.init()
    plugin.attachPreview(nativeView)
  }
  func view() -> UIView { nativeView }
  deinit { plugin?.detachPreview(nativeView) }
}

private final class BeautyPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let plugin: OfflineBeautyPlugin
  init(plugin: OfflineBeautyPlugin) { self.plugin = plugin; super.init() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    BeautyPlatformView(frame: frame, plugin: plugin)
  }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
}
