import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which edge the desktop sidebar docks to. Desktop-only power preference —
/// mobile has no sidebar. Persisted locally (it's a per-device ergonomic
/// choice, not server state).
enum SidebarPosition { left, right }

class SidebarPositionNotifier extends AsyncNotifier<SidebarPosition> {
  static const _key = 'sidebar_position';

  @override
  Future<SidebarPosition> build() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_key);
    return SidebarPosition.values.firstWhere(
      (p) => p.name == name,
      orElse: () => SidebarPosition.left,
    );
  }

  Future<void> set(SidebarPosition position) async {
    state = AsyncData(position);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, position.name);
  }
}

final sidebarPositionProvider =
    AsyncNotifierProvider<SidebarPositionNotifier, SidebarPosition>(
        SidebarPositionNotifier.new);
