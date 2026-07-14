import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Native material surfaces used by the Dart glass widgets.
    engineBridge.pluginRegistry
      .registrar(forPlugin: "vault.native-glass")?
      .register(NativeGlassViewFactory(), withId: "vault/native-glass")
    engineBridge.pluginRegistry
      .registrar(forPlugin: "vault.native-glass-panel")?
      .register(NativeGlassPanelViewFactory(), withId: "vault/native-glass-panel")
    engineBridge.pluginRegistry
      .registrar(forPlugin: "vault.route-picker")?
      .register(RoutePickerViewFactory(), withId: "vault/route-picker")

    // Real SF Symbols: renders UIImage(systemName:) to a white template PNG
    // that the Dart SfSymbolIcon widget tints and caches.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "vault.sf-symbols") {
      let channel = FlutterMethodChannel(
        name: "vault/sf-symbols", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "render",
              let args = call.arguments as? [String: Any],
              let name = args["name"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let points = (args["size"] as? NSNumber)?.doubleValue ?? 24
        let scale = (args["scale"] as? NSNumber)?.doubleValue ?? 3
        let config = UIImage.SymbolConfiguration(
          pointSize: points * scale, weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal),
              let png = image.pngData() else {
          result(FlutterError(
            code: "unknown_symbol", message: "No SF Symbol named \(name)",
            details: nil))
          return
        }
        result(FlutterStandardTypedData(bytes: png))
      }
    }
  }
}
