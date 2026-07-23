import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared geometry + timing for the mobile bottom chrome. One place so the dock
/// pill, mini-player, You circle, and their animations all agree.
const double kDockHeight = 64;
const double kMiniPlayerHeight = 44;

/// The You circle shrinks a touch when the mini-player squeezes in beside it.
const double kYouExpanded = kDockHeight;
const double kYouShrunk = 52;

/// Fraction of the freed row the mini-player claims once fully in. The dock
/// takes the rest — and drops its labels to icon-only while playing, so the
/// narrow dock reads as intentional (not clipped) and the pill gets real room
/// for art + title + a control.
const double kMiniFraction = 0.5;

/// One shared duration/curve for every chrome transition, so the dock's
/// squeeze, the You circle's shrink, and the pill's entrance move as one.
const Duration kChromeAnim = Duration(milliseconds: 380);
const Curve kChromeCurve = Curves.easeOutCubic;

/// Whether the bottom chrome is COLLAPSED, Apple Music-style: the dock tucks
/// into a single 4-box button and the mini player (when active) sits between it
/// and the You circle. Swipe down on the dock to collapse; tap the 4-box to
/// expand. Session state, deliberately not persisted — a fresh launch always
/// starts with full navigation visible.
class DockCollapsed extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final dockCollapsedProvider =
    NotifierProvider<DockCollapsed, bool>(DockCollapsed.new);
