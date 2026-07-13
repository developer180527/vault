import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../core/platform/haptics.dart';
import '../core/platform/platform_info.dart';
import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';
import '../features/media/data/music_player_controller.dart';
import '../features/media/music_player_page.dart';
import 'widgets/action_bar.dart';

/// Mobile layout. The bottom nav is a floating pill dock:
///
///   [ Media │ Files │ Music │ Torrent │ ⊙ You ]
///
/// A static row of the user's pinned services (max [kMaxDockPins]) plus the
/// You slot anchored at the right edge. Nothing scrolls: the dock is a
/// muscle-memory instrument, and the You page carries the full services shelf
/// for everything unpinned. On iOS the pill is translucent "liquid glass"
/// (backdrop blur over the content flowing beneath it).
class MobileShell extends ConsumerWidget {
  const MobileShell({super.key, required this.shell, required this.services});

  final StatefulNavigationShell shell;

  /// Permitted services (already manifest-filtered), in registry order. Their
  /// position here *is* their shell branch index.
  final List<ServiceDefinition> services;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinnedIds =
        ref.watch(pinnedServicesProvider).asData?.value ?? const <String>[];
    // Dock = pinned ∩ permitted, in pin order. 'user' anchors the right slot
    // and is never part of the pinnable row. Capped for display: the desktop
    // sidebar allows unlimited pins, and this device may have been resized /
    // rotated from that layout with more pinned than the dock has slots.
    final dock = [
      for (final id in pinnedIds)
        for (final s in services)
          if (s.id == id && s.id != 'user') s,
    ].take(kMaxDockPins).toList();

    return Scaffold(
      // Content flows underneath the floating pill (and shows through the
      // glass on iOS).
      extendBody: true,
      appBar: AppBar(
        title: Text(services[shell.currentIndex].label),
        actions: [
          ActionBar(actions: services[shell.currentIndex].actions),
          ?services[shell.currentIndex].statusBar?.call(context),
          const SizedBox(width: 8),
        ],
      ),
      body: shell,
      bottomNavigationBar: _BottomBarArea(
        shell: shell,
        services: services,
        dock: dock,
      ),
    );
  }
}

const double _kDockHeight = 64;
const double _kMiniPlayerHeight = 44;

/// The floating stack at the bottom: the music mini-player pill (when a track
/// is loaded) hovering just above the dock pill. Both share the same side
/// margins and the same glass treatment on iOS.
class _BottomBarArea extends ConsumerWidget {
  const _BottomBarArea({
    required this.shell,
    required this.services,
    required this.dock,
  });

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;
  final List<ServiceDefinition> dock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(musicPlayerProvider).current != null;
    // Sit a little lower than the OS-suggested inset (gesture bars reserve
    // more than the pill needs), but never flush against the screen edge.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomGap = math.max(6.0, bottomInset - 10.0);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasTrack) ...[
            const _MiniPlayerPill(),
            const SizedBox(height: 8),
          ],
          _FloatingDock(shell: shell, services: services, dock: dock),
        ],
      ),
    );
  }
}

/// Thin now-playing pill: title, play/pause, next. Tapping it opens the
/// full-screen player (which hides the whole bottom stack).
class _MiniPlayerPill extends ConsumerWidget {
  const _MiniPlayerPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(musicPlayerProvider);
    final controller = ref.read(musicPlayerProvider.notifier);
    final track = state.current;
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return _DockPill(
      radius: _kMiniPlayerHeight / 2,
      child: InkWell(
        onTap: () => Navigator.of(context, rootNavigator: true)
            .push(MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const MusicPlayerPage(),
        )),
        child: SizedBox(
          height: _kMiniPlayerHeight,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Icon(Icons.music_note, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              StreamBuilder<PlayerState>(
                stream: controller.player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: controller.togglePlay,
                  );
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next),
                onPressed: controller.next,
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingDock extends StatelessWidget {
  const _FloatingDock({
    required this.shell,
    required this.services,
    required this.dock,
  });

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  /// The pinned services shown as fixed slots, in pin order.
  final List<ServiceDefinition> dock;

  String get _currentId => services[shell.currentIndex].id;

  int _branchIndexOf(String id) => services.indexWhere((s) => s.id == id);

  void _open(String id) {
    final branch = _branchIndexOf(id);
    if (branch < 0) return;
    VaultHaptics.selection();
    // Re-tapping the active service resets its branch stack.
    shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onUserPage = _currentId == 'user';

    return _DockPill(
      radius: _kDockHeight / 2,
      child: SizedBox(
        height: _kDockHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in dock)
              Expanded(
                child: _DockItem(
                  service: s,
                  selected: !onUserPage && s.id == _currentId,
                  onTap: () => _open(s.id),
                ),
              ),
            VerticalDivider(
                width: 1,
                indent: 14,
                endIndent: 14,
                color: scheme.outlineVariant),
            // The You slot: anchored, opens the services shelf + profile.
            InkWell(
              onTap: () => _open('user'),
              child: SizedBox(
                width: 64,
                child: Center(
                  child: CircleAvatar(
                    radius: 17,
                    backgroundColor: onUserPage
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    child: Icon(
                      onUserPage ? Icons.person : Icons.person_outline,
                      size: 20,
                      color: onUserPage
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pill's surface. iOS gets "liquid glass": a backdrop blur over the
/// content scrolling beneath, a translucent tint, and a hairline highlight —
/// the closest a Flutter-rendered surface gets to the native material (real
/// UIKit glass would need a platform view). Everywhere else it's a plain
/// elevated Material pill.
class _DockPill extends StatelessWidget {
  const _DockPill({required this.child, required this.radius});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(this.radius);

    if (!isIOS) {
      return Material(
        color: scheme.surfaceContainer,
        elevation: 6,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: scheme.surfaceContainer.withValues(alpha: 0.55),
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: 0.10),
              width: 0.5,
            ),
          ),
          // Material keeps InkWell ripples working inside the glass.
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  final ServiceDefinition service;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(selected ? service.selectedIcon : service.icon,
              size: 24, color: color),
          const SizedBox(height: 2),
          Text(
            service.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
          ),
        ],
      ),
    );
  }
}
