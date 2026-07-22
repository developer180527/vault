import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';
import '../core/playback/playback_controller.dart';
import 'bottom_bar/bottom_bar_area.dart';
import 'bottom_bar/metrics.dart';
import 'widgets/action_bar.dart';
import 'widgets/floating_app_bar.dart';

/// Mobile layout, Apple Music-style bottom chrome:
///
///   [ Media │ Files │ Music  ◂pill▸ ]   ( ⊙ You )
///
/// The bottom chrome is a self-contained package under `bottom_bar/`: a dock
/// pill of pinned services (max [kMaxDockPins]) with a sliding selection
/// capsule, a mini-player that squeezes in beside it while a track plays, and a
/// detached You circle. Every surface is a Flutter-drawn GlassSurface (backdrop
/// blur + translucent fill + specular rim), chosen over a native platform view
/// so the chrome can smoothly animate. This file is now just the Scaffold that
/// hosts it. See [BottomBarArea].
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
      // RepaintBoundaries keep the two layers independent: mini-player / capsule
      // updates don't re-rasterize the page, and page scrolling doesn't
      // re-rasterize the chrome — which matters extra here because the chrome
      // runs backdrop-blur filters that would otherwise resample the whole page
      // every frame.
      //
      // Chrome collapse is a ONE-WAY, mini-player-only gesture: scrolling DOWN
      // into content tucks the dock away — but ONLY while a track is playing.
      // Scrolling back UP does NOT restore it; only tapping the collapsed 4-box
      // does. Only vertical, user-initiated scrolls count — horizontal shelves
      // and section swipes must not toggle the chrome.
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
        child: BottomBarArea(shell: shell, services: services, dock: dock),
      ),
    );
  }
}
