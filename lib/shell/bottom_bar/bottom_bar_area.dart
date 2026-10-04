import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/debug/chrome_tuning.dart';
import '../../core/habits/habits.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/services/service_registry.dart';
import 'collapsed_chrome.dart';
import 'expanded_chrome.dart';
import 'metrics.dart';

/// The floating stack at the bottom: the dock pill, the mini-player, and the
/// detached You circle. Swaps between the [ExpandedChrome] and the tucked-away
/// [CollapsedChrome]; the height morph between them is the only thing the
/// [AnimatedSize] animates (the mini-player squeeze is internal to the expanded
/// chrome). Shared side margins; every surface is a Flutter GlassSurface.
class BottomBarArea extends ConsumerWidget {
  const BottomBarArea({
    super.key,
    required this.shell,
    required this.services,
    required this.dock,
  });

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;
  final List<ServiceDefinition> dock;

  String get _currentId => services[shell.currentIndex].id;

  int _branchIndexOf(String id) => services.indexWhere((s) => s.id == id);

  void _open(WidgetRef ref, String id) {
    final branch = _branchIndexOf(id);
    if (branch < 0) return;
    // Learn what gets used (content services only, not the You slot) so the app
    // can suggest / auto-land later. Local-only, best-effort.
    if (id != 'user') {
      ref.read(habitsProvider.notifier).recordServiceOpen(id);
    }
    // No haptic here: native tab bars switch silently.
    // Re-tapping the active service resets its branch stack.
    shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select: this subtree re-lays-out only when the mini-player appears/
    // disappears, not on every playback event (track advance, video open).
    final tune = ref.watch(chromeTuningProvider);
    final hasTrack =
        ref.watch(playbackProvider.select((s) => s.currentAudio != null));
    final onUserPage = _currentId == 'user';
    // Sit a little lower than the OS-suggested inset (gesture bars reserve more
    // than the chrome needs), but never flush against the screen edge.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomGap = math.max(6.0, bottomInset - tune.bottomLift);

    // NOT `tune.forceCollapsed || ...` — that pinned the dock collapsed and
    // swallowed the tap to expand, leaving the chrome dead to the touch. The
    // tuning switch drives the real provider instead (see the panel), so
    // normal interaction keeps working while tuning.
    final collapsed = ref.watch(dockCollapsedProvider);
    void open(String id) => _open(ref, id);

    return Padding(
      padding: EdgeInsets.fromLTRB(
          tune.sideMargin, 0, tune.sideMargin, bottomGap),
      child: AnimatedSize(
        duration: tune.anim,
        curve: tune.flutterCurve,
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: tune.switcher,
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween(begin: tune.switcherScale, end: 1.0)
                  .animate(anim),
              child: child,
            ),
          ),
          child: collapsed
              ? CollapsedChrome(
                  key: const ValueKey('collapsed'),
                  hasTrack: hasTrack,
                  onUserPage: onUserPage,
                  onExpand: () =>
                      ref.read(dockCollapsedProvider.notifier).set(false),
                  onYou: () => open('user'),
                )
              : ExpandedChrome(
                  key: const ValueKey('expanded'),
                  hasTrack: hasTrack,
                  onUserPage: onUserPage,
                  dock: dock,
                  currentId: _currentId,
                  onOpen: open,
                  onCollapse: () =>
                      ref.read(dockCollapsedProvider.notifier).set(true),
                ),
        ),
      ),
    );
  }
}
