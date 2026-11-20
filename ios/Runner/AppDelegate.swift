import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var appInfoChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OfflineAppInfoPlugin") {
      let channel = FlutterMethodChannel(name: "offline_nail/app_info", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "getVersion" {
          result(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        } else if call.method == "getCameraDeviceOrientation" {
          // The camera backend uses UIDevice's physical pose for AF/AE points.
          // Dart's four-direction stream retains its last pose when flat.
          switch UIDevice.current.orientation {
          case .portrait: result("portraitUp")
          case .portraitUpsideDown: result("portraitDown")
          case .landscapeLeft: result("landscapeLeft")
          case .landscapeRight: result("landscapeRight")
          case .faceUp, .faceDown: result("flat")
          default: result("unknown")
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      appInfoChannel = channel
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OfflineBeautyPlugin") {
      OfflineBeautyPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OfflineHandLandmarkerPlugin") {
      OfflineHandLandmarkerPlugin.register(with: registrar)
    }
  }
}
