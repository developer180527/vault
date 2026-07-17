import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../core/platform/design/adaptive_icons.dart';
import '../core/platform/design/native_glass.dart';
import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';
import '../core/playback/playback_controller.dart';
import '../features/media/music_player_page.dart';
import 'widgets/action_bar.dart';
import 'widgets/glass_app_bar.dart';

/// Mobile layout, Apple Music-style bottom chrome:
///
///   [ mini-player pill (when a track is loaded)      ]
///   [ Media │ Files │ Music │ Torrent ]   ( ⊙ You )
///
/// A static dock pill holds the pinned services (max [kMaxDockPins]) with a
/// capsule highlight on the active tab; the You slot is a detached circular
/// button. Every surface renders in the platform's design language via
/// [NativeGlassSurface] — real UIKit liquid glass on iOS, elevated Material
/// elsewhere — and icons resolve to SF Symbols on Apple platforms.
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
    // Dock = pinned ∩ permitted, in pin order. 'user' anchors the detached
    // circle and is never part of the pinnable row. Capped for display: the
    // desktop sidebar allows unlimited pins and this device may have been
    // resized/rotated from that layout with more pinned than the dock holds.
    final dock = [
      for (final id in pinnedIds)
        for (final s in services)
          if (s.id == id && s.id != 'user') s,
    ].take(kMaxDockPins).toList();

    return Scaffold(
      // Content flows underneath the floating chrome (and shows through the
      // glass) at BOTH edges: the toolbar and the dock are translucent layers
      // the page scrolls beneath.
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: Text(services[shell.currentIndex].label),
        actions: [
          ActionBar(actions: services[shell.currentIndex].actions),
          ?services[shell.currentIndex].statusBar?.call(context),
          const SizedBox(width: 8),
        ],
      ),
      // RepaintBoundaries keep the two layers independent: mini-player /
      // capsule updates don't re-rasterize the page, and page scrolling
      // doesn't re-rasterize the chrome — which matters extra here because
      // the chrome holds platform views (hybrid-composition layer splits).
      body: RepaintBoundary(child: shell),
      bottomNavigationBar: RepaintBoundary(
        child: _BottomBarArea(shell: shell, services: services, dock: dock),
      ),
    );
  }
}

const double _kDockHeight = 64;
const double _kMiniPlayerHeight = 44;

/// The floating stack at the bottom: mini-player pill above, then the dock
/// pill and the detached You circle. Shared side margins; every surface gets
/// the platform material from [NativeGlassSurface].
class _BottomBarArea extends ConsumerWidget {
  const _BottomBarArea({
    required this.shell,
    required this.services,
    required this.dock,
  });

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;
  final List<ServiceDefinition> dock;

  String get _currentId => services[shell.currentIndex].id;

  int _branchIndexOf(String id) => services.indexWhere((s) => s.id == id);

  void _open(String id) {
    final branch = _branchIndexOf(id);
    if (branch < 0) return;
    // No haptic here: native tab bars switch silently.
    // Re-tapping the active service resets its branch stack.
    shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select: this subtree hosts the native glass PANEL (platform view) — it
    // must re-layout only when the mini-player appears/disappears, not on
    // every playback event (track advance, video open/close).
    final hasTrack = ref.watch(
      playbackProvider.select((s) => s.currentAudio != null),
    );
    final onUserPage = _currentId == 'user';
    // Sit a little lower than the OS-suggested inset (gesture bars reserve
    // more than the chrome needs), but never flush against the screen edge.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomGap = math.max(6.0, bottomInset - 10.0);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          // Chrome geometry, shared by the Flutter layout below and the native
          // glass panel behind it (one platform view for all surfaces).
          final dockTop = hasTrack ? _kMiniPlayerHeight + 8.0 : 0.0;
          final height = dockTop + _kDockHeight;
          final chrome = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasTrack) ...[
                const _MiniPlayerPill(),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    child: NativeGlassSurface(
                      radius: _kDockHeight / 2,
                      child: SizedBox(
                        height: _kDockHeight,
                        // Inner padding keeps the end slots clear of the pill's
                        // curved ends, so the capsule geometry is identical for
                        // every slot — including the extremes.
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: _DockRow(
                            dock: dock,
                            selectedIndex: onUserPage
                                ? -1
                                : dock.indexWhere((s) => s.id == _currentId),
                            onTap: (s) => _open(s.id),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // The You slot: a detached circle, Apple Music-style.
                  NativeGlassSurface(
                    radius: _kDockHeight / 2,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _open('user'),
                      child: SizedBox(
                        width: _kDockHeight,
                        height: _kDockHeight,
                        child: Center(
                          child: CircleAvatar(
                            radius: 17,
                            backgroundColor: onUserPage
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                            child: AdaptiveIcon(
                              VaultIcons.user,
                              selected: onUserPage,
                              size: 20,
                              color: onUserPage
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );

          return NativeGlassPanel(
            size: Size(width, height),
            regions: [
              if (hasTrack)
                GlassRegion(
                  rect: Rect.fromLTWH(0, 0, width, _kMiniPlayerHeight),
                  radius: _kMiniPlayerHeight / 2,
                ),
              GlassRegion(
                rect: Rect.fromLTWH(
                  0,
                  dockTop,
                  width - _kDockHeight - 8,
                  _kDockHeight,
                ),
                radius: _kDockHeight / 2,
              ),
              GlassRegion(
                rect: Rect.fromLTWH(
                  width - _kDockHeight,
                  dockTop,
                  _kDockHeight,
                  _kDockHeight,
                ),
                radius: _kDockHeight / 2,
              ),
            ],
            child: chrome,
          );
        },
      ),
    );
  }
}

/// The dock slots with a single selection capsule that SLIDES between them
/// (spring-out curve), like the native tab bar's lozenge — rather than each
/// slot lighting up its own highlight.
class _DockRow extends StatelessWidget {
  const _DockRow({
    required this.dock,
    required this.selectedIndex,
    required this.onTap,
  });

  final List<ServiceDefinition> dock;

  /// -1 = nothing selected (the You page is active).
  final int selectedIndex;
  final ValueChanged<ServiceDefinition> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (dock.isEmpty) return const SizedBox.shrink();
    final n = dock.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slotWidth = width / n;
        // The dock row sits inside the pill with its own horizontal padding,
        // so every slot — including the extremes — has identical geometry and
        // the capsule is simply centered on its slot. No edge clamping: that
        // asymmetry was what made the end slots look wrong.
        final capsuleWidth = math.min(slotWidth + 6, width);
        final i = selectedIndex.clamp(0, n - 1);
        final left = i * slotWidth + (slotWidth - capsuleWidth) / 2;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutBack,
              left: left,
              top: 7,
              width: capsuleWidth,
              height: _kDockHeight - 14,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: selectedIndex < 0 ? 0 : 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(
                      (_kDockHeight - 14) / 2,
                    ),
                  ),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < n; i++)
                  Expanded(
                    child: _DockItem(
                      service: dock[i],
                      selected: i == selectedIndex,
                      onTap: () => onTap(dock[i]),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// One dock slot: icon + label. The selection capsule is drawn by [_DockRow].
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
    // GestureDetector, not InkWell: native tab bars have no ripple/highlight.
    // The raw detector has NO semantics of its own, so declare the tab role
    // explicitly — otherwise the whole dock is invisible to screen readers.
    return Semantics(
      button: true,
      selected: selected,
      label: '${service.label} tab',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ExcludeSemantics(
              child: AdaptiveIcon(
                service.icon,
                selected: selected,
                size: 22,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            ExcludeSemantics(
              child: Text(
                service.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
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
    final controller = ref.read(playbackProvider.notifier);
    // select: rebuild on track changes only — video session churn is not this
    // pill's business.
    final track = ref.watch(playbackProvider.select((s) => s.currentAudio));
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return NativeGlassSurface(
      radius: _kMiniPlayerHeight / 2,
      child: InkWell(
        onTap: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => const MusicPlayerPage(),
          ),
        ),
        child: SizedBox(
          height: _kMiniPlayerHeight,
          child: Row(
            children: [
              const SizedBox(width: 16),
              ExcludeSemantics(
                child: AdaptiveIcon(
                  VaultIcons.music,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  label: 'Now playing: ${track.title}. Opens the player.',
                  button: true,
                  child: ExcludeSemantics(
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
              StreamBuilder<PlayerState>(
                stream: controller.player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: playing ? 'Pause' : 'Play',
                    icon: AdaptiveIcon(
                      playing ? VaultIcons.pause : VaultIcons.play,
                      size: 20,
                    ),
                    onPressed: controller.togglePlay,
                  );
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Next track',
                icon: const AdaptiveIcon(VaultIcons.skipNext, size: 20),
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
