import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerSfSymbolsChannel(flutterViewController)

    super.awakeFromNib()
  }

  /// Real SF Symbols: renders NSImage(systemSymbolName:) to a white template
  /// PNG that the Dart SfSymbolIcon widget tints and caches.
  private func registerSfSymbolsChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "vault/sf-symbols", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "render",
            let args = call.arguments as? [String: Any],
            let name = args["name"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard #available(macOS 11.0, *) else {
        // Pre-Big Sur has no SF Symbols; Dart falls back to Material glyphs.
        result(FlutterError(
          code: "unavailable", message: "SF Symbols need macOS 11+",
          details: nil))
        return
      }
      let points = (args["size"] as? NSNumber)?.doubleValue ?? 24
      let scale = (args["scale"] as? NSNumber)?.doubleValue ?? 2
      let config = NSImage.SymbolConfiguration(
        pointSize: points * scale, weight: .regular)
      guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
              .withSymbolConfiguration(config) else {
        result(FlutterError(
          code: "unknown_symbol", message: "No SF Symbol named \(name)",
          details: nil))
        return
      }

      let size = symbol.size
      guard size.width > 0, size.height > 0,
            let bitmap = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: Int(ceil(size.width)),
              pixelsHigh: Int(ceil(size.height)),
              bitsPerSample: 8,
              samplesPerPixel: 4,
              hasAlpha: true,
              isPlanar: false,
              colorSpaceName: .deviceRGB,
              bytesPerRow: 0,
              bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        result(FlutterError(
          code: "render_failed", message: "Could not rasterize \(name)",
          details: nil))
        return
      }

      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      symbol.draw(in: NSRect(origin: .zero, size: size))
      // Tint the glyph white so Dart can recolor it per theme.
      NSColor.white.set()
      NSRect(origin: .zero, size: size).fill(using: .sourceIn)
      NSGraphicsContext.restoreGraphicsState()

      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        result(FlutterError(
          code: "render_failed", message: "PNG encode failed for \(name)",
          details: nil))
        return
      }
      result(FlutterStandardTypedData(bytes: png))
    }
  }
}
