import 'dart:async';

/// A local notification the app raises itself (e.g. "Backup complete").
class LocalNotification {
  const LocalNotification({
    required this.id,
    required this.title,
    this.body,
  });

  final String id;
  final String title;
  final String? body;
}

/// A user tapping a notification (or one of its actions), surfaced so the app
/// can route to the relevant screen.
class NotificationTap {
  const NotificationTap({required this.id, this.action});
  final String id;
  final String? action;
}

/// Port for notifications and device push registration. The seam here is push
/// vs tray: mobile has server push (APNs/FCM) but no tray; desktop has a
/// persistent tray/native notifications; web has neither reliably.
/// Implementations: `ApnsFcmNotifications` (mobile), `DesktopNotifications`
/// (native + tray), `WebNotifications`.
abstract interface class Notifications {
  /// Server can wake this device with a push message (needs [pushToken]).
  bool get supportsPush;

  /// A resident tray/menu-bar presence exists (desktop) — relevant to how the
  /// background daemon surfaces itself.
  bool get supportsTray;

  Future<bool> requestPermission();

  Future<void> show(LocalNotification notification);

  /// The device push token to register with the home server, or null where
  /// push isn't available.
  Future<String?> pushToken();

  /// Taps on notifications, for routing.
  Stream<NotificationTap> taps();
}

/// Default until host implementations land: grants nothing, shows nothing.
class StubNotifications implements Notifications {
  const StubNotifications();

  @override
  bool get supportsPush => false;

  @override
  bool get supportsTray => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> show(LocalNotification notification) async {}

  @override
  Future<String?> pushToken() async => null;

  @override
  Stream<NotificationTap> taps() => const Stream.empty();
}
