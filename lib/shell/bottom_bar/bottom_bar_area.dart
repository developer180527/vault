import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    // Sit a little lower than the OS-suggested inset (gesture bars reserve more
    // than the chrome needs), but never flush against the screen edge.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomGap = math.max(6.0, bottomInset - 10.0);

    final collapsed = ref.watch(dockCollapsedProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
      child: AnimatedSize(
        duration: kChromeAnim,
        curve: kChromeCurve,
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween(begin: 0.97, end: 1.0).animate(anim),
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
                  onYou: () => _open('user'),
                )
              : ExpandedChrome(
                  key: const ValueKey('expanded'),
                  hasTrack: hasTrack,
                  onUserPage: onUserPage,
                  dock: dock,
                  currentId: _currentId,
                  onOpen: _open,
                  onCollapse: () =>
                      ref.read(dockCollapsedProvider.notifier).set(true),
                ),
        ),
      ),
    );
  }
}
