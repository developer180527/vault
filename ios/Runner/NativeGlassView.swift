import AVFoundation
import AVKit
import Flutter
import UIKit

/// The current audio output device's display name (e.g. "Speaker",
/// "Rockerz 551 ANC Pro"). Empty route falls back to "iPhone".
func currentAudioOutputName() -> String {
  let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
  return outputs.first?.portName ?? "iPhone"
}

/// Streams the output device name to Dart on every route change (Bluetooth
/// connect/disconnect, AirPlay, headphones plug), plus once on subscribe.
class AudioRouteStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    NotificationCenter.default.addObserver(
      self, selector: #selector(routeChanged),
      name: AVAudioSession.routeChangeNotification, object: nil)
    emit()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    sink = nil
    return nil
  }

  @objc private func routeChanged(_ note: Notification) { emit() }

  private func emit() {
    let name = currentAudioOutputName()
    DispatchQueue.main.async { [weak self] in self?.sink?(name) }
  }
}

/// Shared builder: liquid glass (UIGlassEffect) on iOS 26+, system-material
/// blur before that. Corner radius comes from Dart so the native clip matches
/// the Flutter-side rounding exactly.
private func makeGlassView(radius: CGFloat, frame: CGRect) -> UIVisualEffectView {
  let effectView: UIVisualEffectView
  if #available(iOS 26.0, *) {
    let glass = UIGlassEffect()
    // Interactive glass gets the live lensing/shimmer response.
    glass.isInteractive = true
    effectView = UIVisualEffectView(effect: glass)
  } else {
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  }
  effectView.frame = frame
  effectView.layer.cornerRadius = radius
  effectView.layer.cornerCurve = .continuous
  effectView.clipsToBounds = true
  return effectView
}

/// Factory for "vault/native-glass": a single rounded glass surface.
class NativeGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativeGlassView(frame: frame, args: args as? [String: Any])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class NativeGlassView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect, args: [String: Any]?) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false

    let radius = (args?["cornerRadius"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    let effectView = makeGlassView(radius: radius, frame: container.bounds)
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(effectView)

    super.init()
  }

  func view() -> UIView {
    return container
  }
}

/// Factory for "vault/native-glass-panel": ONE platform view hosting several
/// glass regions (dock pill, You circle, mini player). Flutter pays the
/// hybrid-composition layer split once instead of once per surface — three
/// separate platform views caused frame-scheduler contention (visible
/// flicker and "reported frame time is older" warnings).
class NativeGlassPanelViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativeGlassPanelView(frame: frame, args: args as? [String: Any])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Factory for "vault/route-picker": the system AirPlay/audio-output picker
/// (AVRoutePickerView). Interactive — tapping it presents the route sheet.
class RoutePickerViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return RoutePickerPlatformView(frame: frame, args: args as? [String: Any])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class RoutePickerPlatformView: NSObject, FlutterPlatformView {
  private let picker: AVRoutePickerView

  init(frame: CGRect, args: [String: Any]?) {
    picker = AVRoutePickerView(frame: frame)
    if let argb = (args?["tint"] as? NSNumber)?.uint32Value {
      let color = UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: CGFloat((argb >> 24) & 0xFF) / 255)
      picker.tintColor = color
      picker.activeTintColor = color
    }
    super.init()
  }

  func view() -> UIView {
    return picker
  }
}

class NativeGlassPanelView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect, args: [String: Any]?) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false

    // Regions arrive in logical points: {x, y, w, h, r}.
    let regions = (args?["regions"] as? [[String: Any]]) ?? []
    for region in regions {
      func num(_ key: String) -> CGFloat {
        (region[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
      }
      let rect = CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h"))
      container.addSubview(makeGlassView(radius: num("r"), frame: rect))
    }

    super.init()
  }

  func view() -> UIView {
    return container
  }
}
