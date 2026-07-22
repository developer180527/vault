import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../core/platform/design/adaptive_icons.dart';
import '../core/platform/design/glass_surface.dart';
import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';
import '../core/playback/playable.dart';
import '../core/playback/playback_controller.dart';
import '../features/media/data/server_music.dart';
import '../features/media/music_player_page.dart';
import 'widgets/action_bar.dart';
import 'widgets/floating_app_bar.dart';

/// Mobile layout, Apple Music-style bottom chrome:
///
///   [ mini-player pill (when a track is loaded)      ]
///   [ Media │ Files │ Music │ Torrent ]   ( ⊙ You )
///
/// A static dock pill holds the pinned services (max [kMaxDockPins]) with a
/// capsule highlight on the active tab; the You slot is a detached circular
/// button. Every surface renders through [GlassSurface] — a Flutter-drawn
/// glassmorphic surface (backdrop blur + translucent fill + hairline edge),
/// chosen over a native platform view so the chrome can smoothly animate
/// (the mini-player grows in). Icons resolve to SF Symbols on Apple platforms.
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
      appBar: FloatingAppBar(
        title: Text(services[shell.currentIndex].label),
        actions: [
          ActionBar(
              actions: services[shell.currentIndex].actions, floating: true),
          ?services[shell.currentIndex].statusBar?.call(context),
          const SizedBox(width: 8),
        ],
      ),
      // RepaintBoundaries keep the two layers independent: mini-player /
      // capsule updates don't re-rasterize the page, and page scrolling
      // doesn't re-rasterize the chrome — which matters extra here because the
      // chrome runs backdrop-blur filters that would otherwise resample the
      // whole page every frame.
      //
      // Chrome collapse is a ONE-WAY, mini-player-only gesture: scrolling DOWN
      // into content tucks the dock away — but ONLY while a track is playing
      // (there's no point collapsing to a bare 4-box with nothing to show).
      // Scrolling back UP does NOT restore it; only tapping the collapsed
      // 4-box does. Only vertical, user-initiated scrolls count — horizontal
      // shelves and section swipes must not toggle the chrome.
      body: NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis != Axis.vertical) return false;
          if (n.direction == ScrollDirection.reverse &&
              ref.read(playbackProvider).currentAudio != null) {
            ref.read(dockCollapsedProvider.notifier).set(true);
          }
          return false; // observe only — never eat the notification
        },
        child: RepaintBoundary(child: shell),
      ),
      bottomNavigationBar: RepaintBoundary(
        child: _BottomBarArea(shell: shell, services: services, dock: dock),
      ),
    );
  }
}

const double _kDockHeight = 64;
const double _kMiniPlayerHeight = 44;

/// One shared duration/curve for the chrome's size + content animations, so the
/// mini-player's fade/slide and the height it grows into stay in lockstep.
const Duration _kChromeAnim = Duration(milliseconds: 360);
const Curve _kChromeCurve = Curves.easeOutCubic;

/// Whether the bottom chrome is COLLAPSED, Apple Music-style: the dock tucks
/// into a single 4-box button and the mini player (when active) sits between
/// it and the You circle, all on one row. Swipe down on the dock to collapse;
/// tap the 4-box to expand. Session state, deliberately not persisted — a
/// fresh launch always starts with full navigation visible.
class DockCollapsed extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final dockCollapsedProvider =
    NotifierProvider<DockCollapsed, bool>(DockCollapsed.new);

/// The floating stack at the bottom: mini-player pill above, then the dock
/// pill and the detached You circle. Shared side margins; every surface gets
/// the material from [GlassSurface].
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
    // select: this subtree re-lays-out only when the mini-player appears/
    // disappears, not on every playback event (track advance, video open).
    final hasTrack = ref.watch(
      playbackProvider.select((s) => s.currentAudio != null),
    );
    final onUserPage = _currentId == 'user';
    // Sit a little lower than the OS-suggested inset (gesture bars reserve
    // more than the chrome needs), but never flush against the screen edge.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomGap = math.max(6.0, bottomInset - 10.0);

    final collapsed = ref.watch(dockCollapsedProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Two chrome layouts share one animated shell: AnimatedSize morphs
          // the height, AnimatedSwitcher crossfades the contents.
          final child = collapsed
              ? _CollapsedChrome(
                  key: const ValueKey('collapsed'),
                  hasTrack: hasTrack,
                  onUserPage: onUserPage,
                  onExpand: () =>
                      ref.read(dockCollapsedProvider.notifier).set(false),
                  onYou: () => _open('user'),
                )
              : _ExpandedChrome(
                  key: const ValueKey('expanded'),
                  hasTrack: hasTrack,
                  onUserPage: onUserPage,
                  dock: dock,
                  currentId: _currentId,
                  onOpen: _open,
                  onCollapse: () =>
                      ref.read(dockCollapsedProvider.notifier).set(true),
                );

          return AnimatedSize(
            duration: _kChromeAnim,
            curve: _kChromeCurve,
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0)
                    .animate(anim), child: child),
              ),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// The full bottom chrome: mini-player above, dock pill + You circle below.
/// Swiping DOWN on the dock tucks it away into [_CollapsedChrome].
///
/// Stateful for the mini-player ENTRANCE: when a track starts (hasTrack goes
/// true while expanded), one controller drives the pill sliding up + fading +
/// scaling into place, and — the same beat — the dock and You buttons do a
/// small settle, so the new pill reads as pushing them into position rather
/// than popping in. (The native glass panel behind snaps to the new layout —
/// it's a platform view that can't tween — so the entrance animates the
/// Flutter content over it.)
class _ExpandedChrome extends StatefulWidget {
  const _ExpandedChrome({
    super.key,
    required this.hasTrack,
    required this.onUserPage,
    required this.dock,
    required this.currentId,
    required this.onOpen,
    required this.onCollapse,
  });

  final bool hasTrack;
  final bool onUserPage;
  final List<ServiceDefinition> dock;
  final String currentId;
  final void Function(String id) onOpen;
  final VoidCallback onCollapse;

  @override
  State<_ExpandedChrome> createState() => _ExpandedChromeState();
}

class _ExpandedChromeState extends State<_ExpandedChrome>
    with SingleTickerProviderStateMixin {
  // Matched to the parent AnimatedSize (_kChromeAnim) so the pill's content
  // and the height it grows into move as one.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: _kChromeAnim,
  );

  @override
  void initState() {
    super.initState();
    // Already-playing when this chrome mounts (e.g. re-expanding) → no entrance.
    if (widget.hasTrack) _entrance.value = 1;
  }

  @override
  void didUpdateWidget(_ExpandedChrome old) {
    super.didUpdateWidget(old);
    if (widget.hasTrack && !old.hasTrack) {
      _entrance.forward(from: 0);
    } else if (!widget.hasTrack && old.hasTrack) {
      _entrance.value = 0;
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = widget.hasTrack;

    final dockRow = Row(
      children: [
        Expanded(
          child: GlassSurface(
            radius: _kDockHeight / 2,
            // Swipe down on the dock pill → collapsed chrome.
            child: GestureDetector(
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 250) widget.onCollapse();
              },
              child: SizedBox(
                height: _kDockHeight,
                // Wider inner padding so even the end slots' selection capsule
                // stays inside the pill's straight middle, never poking into
                // the rounded cap (where the ClipRRect would shave it — the
                // "glow cutout").
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _DockRow(
                    dock: widget.dock,
                    selectedIndex: widget.onUserPage
                        ? -1
                        : widget.dock
                            .indexWhere((s) => s.id == widget.currentId),
                    onTap: (s) => widget.onOpen(s.id),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _YouCircle(
            selected: widget.onUserPage, onTap: () => widget.onOpen('user')),
      ],
    );

    // The mini-player entrance is driven by ONE controller doing only the
    // CONTENT (fade + slide-up + a small button settle). The height growth is
    // owned solely by the parent AnimatedSize (matched duration/curve) — having
    // both animate height was what made it feel janky. Slide starts below and
    // eases up as the space opens, so the pill rises into place.
    return AnimatedBuilder(
      animation: _entrance,
      builder: (context, _) {
        final e = _entrance.value;
        final fade = Curves.easeOut.transform(e);
        final rise = (1 - Curves.easeOutCubic.transform(e)) * 14.0;
        final settle = 0.97 + 0.03 * Curves.easeOut.transform(e);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasTrack) ...[
              Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, rise),
                  child: const GlassSurface(
                    radius: _kMiniPlayerHeight / 2,
                    child: _MiniPlayerPill(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Transform.scale(scale: settle, child: dockRow),
          ],
        );
      },
    );
  }
}

/// The tucked-away chrome, one row: a 4-box button (tap → expand), the mini
/// player stretched between (when a track is loaded), and the You circle.
class _CollapsedChrome extends StatelessWidget {
  const _CollapsedChrome({
    super.key,
    required this.hasTrack,
    required this.onUserPage,
    required this.onExpand,
    required this.onYou,
  });

  final bool hasTrack;
  final bool onUserPage;
  final VoidCallback onExpand;
  final VoidCallback onYou;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Collapsed, everything shrinks to the mini-player's height so the 4-box,
    // the pill, and the You circle read as one consistent 44pt row.
    const h = _kMiniPlayerHeight;
    return SizedBox(
      height: h,
      child: Row(
        children: [
          // The 4-box: tap to bring the full dock back.
          GlassSurface(
            radius: h / 2,
            child: Semantics(
              button: true,
              label: 'Show navigation',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onExpand,
                child: SizedBox(
                  width: h,
                  height: h,
                  child: Icon(
                    Icons.grid_view_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: hasTrack
                ? GlassSurface(
                    radius: h / 2, child: const _MiniPlayerPill())
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 8),
          _YouCircle(selected: onUserPage, onTap: onYou, size: h),
        ],
      ),
    );
  }
}

/// The detached You circle, Apple Music-style — shared by both chrome states.
/// [size] shrinks it in the collapsed row to match the mini player. Always the
/// person glyph (never the profile picture) — the avatar lives on the You page;
/// the dock stays a clean, consistent tab symbol.
class _YouCircle extends StatelessWidget {
  const _YouCircle({
    required this.selected,
    required this.onTap,
    this.size = _kDockHeight,
  });

  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSurface(
      radius: size / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: CircleAvatar(
              radius: size * 0.27,
              backgroundColor: selected
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              child: AdaptiveIcon(
                VaultIcons.user,
                selected: selected,
                size: size * 0.31,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
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
        // Capsule fits WITHIN its slot (never wider), so it can't spill past
        // the slot into the pill's rounded cap and get clipped. A small inset
        // (top/bottom 10, ~4px side gap) also gives the corners clearance.
        const vInset = 10.0;
        final capsuleHeight = _kDockHeight - vInset * 2;
        final capsuleWidth = math.max(0.0, slotWidth - 4);
        final i = selectedIndex.clamp(0, n - 1);
        final left = i * slotWidth + (slotWidth - capsuleWidth) / 2;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeOutCubic,
              left: left,
              top: vInset,
              width: capsuleWidth,
              height: capsuleHeight,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: selectedIndex < 0 ? 0 : 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(capsuleHeight / 2),
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

/// Mini-player leading art: embedded bytes (local files) or bearer-cached
/// network art (server streams), music-note fallback.
class _MiniArt extends ConsumerWidget {
  const _MiniArt({required this.track});

  final Playable track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = track.artwork ??
        (track.artworkUri == null
            ? null
            : ref
                .watch(artBytesProvider(track.artworkUri!.toString()))
                .asData
                ?.value);
    const side = _kMiniPlayerHeight - 12;
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        width: side,
        height: side,
        child: bytes != null
            ? Image.memory(bytes,
                fit: BoxFit.cover, cacheWidth: 96, gaplessPlayback: true)
            : ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: AdaptiveIcon(VaultIcons.music,
                    size: 16, color: scheme.primary),
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

    // Glass is provided by the enclosing GlassSurface; here we just add a
    // transparent Material so the InkWell splash renders on top of it.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // Guarded opener: a pill tap while the player is already up (or a
        // double-tap) must not stack a second copy.
        onTap: () => openMusicPlayer(context),
        child: SizedBox(
          height: _kMiniPlayerHeight,
          child: Row(
            children: [
              const SizedBox(width: 8),
              // Album art (embedded bytes or cached network art); the music
              // glyph is only the no-art fallback.
              ExcludeSemantics(child: _MiniArt(track: track)),
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
