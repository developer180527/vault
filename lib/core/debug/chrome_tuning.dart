import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live-tunable geometry and timing for the mobile bottom chrome.
///
/// This exists so the dock/mini-player proportions can be dialled in ON A REAL
/// PHONE, with the thing you're tuning visible underneath the sliders, instead
/// of being described in words and guessed at a round-trip at a time. The
/// values here are the ONLY source of truth while tuning; once a layout is
/// settled, [toDartCode] emits the constants to paste back into
/// `shell/bottom_bar/metrics.dart`, and this whole panel can be deleted.
///
/// Defaults below are exactly today's shipped constants, so opening the panel
/// changes nothing until a slider moves.
@immutable
class ChromeTuning {
  const ChromeTuning({
    this.dockHeight = 64,
    this.miniHeight = 44,
    this.miniFraction = 0.5,
    this.youExpanded = 64,
    this.youShrunk = 52,
    this.gap = 8,
    this.sideMargin = 16,
    this.bottomLift = 10,
    this.animMs = 380,
    this.curve = ChromeCurve.easeOutCubic,
    this.fadeStart = 0.15,
    this.switcherMs = 250,
    this.switcherScale = 0.97,
    this.forceMini = false,
    this.forceCollapsed = false,
  });

  /// Height of the dock pill (and the row).
  final double dockHeight;

  /// Height of the mini-player's glass pill inside that row.
  final double miniHeight;

  /// Share of the row (after the You circle) the mini-player claims.
  final double miniFraction;

  /// You circle diameter with no track playing / while one plays.
  final double youExpanded;
  final double youShrunk;

  /// Gap between dock, mini-player and You circle.
  final double gap;

  /// Left/right margin of the whole chrome.
  final double sideMargin;

  /// Subtracted from the OS bottom inset — gesture bars reserve more room than
  /// the chrome needs, so the chrome sits slightly lower than the raw inset.
  final double bottomLift;

  /// The one shared transition duration + curve.
  final int animMs;
  final ChromeCurve curve;

  /// Where in the squeeze the mini-player starts fading in (0–1).
  final double fadeStart;

  /// The collapsed↔expanded cross-fade.
  final int switcherMs;
  final double switcherScale;

  // --- preview-only, never emitted as code ---

  /// Show the mini-player without actually playing anything, so both states
  /// can be tuned without hunting for a track.
  final bool forceMini;
  final bool forceCollapsed;

  Curve get flutterCurve => curve.value;
  Duration get anim => Duration(milliseconds: animMs);
  Duration get switcher => Duration(milliseconds: switcherMs);

  ChromeTuning copyWith({
    double? dockHeight,
    double? miniHeight,
    double? miniFraction,
    double? youExpanded,
    double? youShrunk,
    double? gap,
    double? sideMargin,
    double? bottomLift,
    int? animMs,
    ChromeCurve? curve,
    double? fadeStart,
    int? switcherMs,
    double? switcherScale,
    bool? forceMini,
    bool? forceCollapsed,
  }) =>
      ChromeTuning(
        dockHeight: dockHeight ?? this.dockHeight,
        miniHeight: miniHeight ?? this.miniHeight,
        miniFraction: miniFraction ?? this.miniFraction,
        youExpanded: youExpanded ?? this.youExpanded,
        youShrunk: youShrunk ?? this.youShrunk,
        gap: gap ?? this.gap,
        sideMargin: sideMargin ?? this.sideMargin,
        bottomLift: bottomLift ?? this.bottomLift,
        animMs: animMs ?? this.animMs,
        curve: curve ?? this.curve,
        fadeStart: fadeStart ?? this.fadeStart,
        switcherMs: switcherMs ?? this.switcherMs,
        switcherScale: switcherScale ?? this.switcherScale,
        forceMini: forceMini ?? this.forceMini,
        forceCollapsed: forceCollapsed ?? this.forceCollapsed,
      );

  Map<String, Object?> toJson() => {
        'dockHeight': dockHeight,
        'miniHeight': miniHeight,
        'miniFraction': miniFraction,
        'youExpanded': youExpanded,
        'youShrunk': youShrunk,
        'gap': gap,
        'sideMargin': sideMargin,
        'bottomLift': bottomLift,
        'animMs': animMs,
        'curve': curve.name,
        'fadeStart': fadeStart,
        'switcherMs': switcherMs,
        'switcherScale': switcherScale,
      };

  static ChromeTuning fromJson(Map<String, Object?> j) {
    double d(String k, double fallback) =>
        (j[k] as num?)?.toDouble() ?? fallback;
    const def = ChromeTuning();
    return ChromeTuning(
      dockHeight: d('dockHeight', def.dockHeight),
      miniHeight: d('miniHeight', def.miniHeight),
      miniFraction: d('miniFraction', def.miniFraction),
      youExpanded: d('youExpanded', def.youExpanded),
      youShrunk: d('youShrunk', def.youShrunk),
      gap: d('gap', def.gap),
      sideMargin: d('sideMargin', def.sideMargin),
      bottomLift: d('bottomLift', def.bottomLift),
      animMs: (j['animMs'] as num?)?.toInt() ?? def.animMs,
      curve: ChromeCurve.values.firstWhere(
        (c) => c.name == j['curve'],
        orElse: () => def.curve,
      ),
      fadeStart: d('fadeStart', def.fadeStart),
      switcherMs: (j['switcherMs'] as num?)?.toInt() ?? def.switcherMs,
      switcherScale: d('switcherScale', def.switcherScale),
    );
  }

  /// The settled values, as the constants to paste into metrics.dart. This is
  /// how the tuning leaves the phone — copy it out of the panel and hand it
  /// over; nothing here needs to read the device's preferences.
  String toDartCode() {
    String f(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    return '''
const double kDockHeight = ${f(dockHeight)};
const double kMiniPlayerHeight = ${f(miniHeight)};
const double kYouExpanded = ${f(youExpanded)};
const double kChromeGap = ${f(gap)};
const double kChromeSideMargin = ${f(sideMargin)};
const double kChromeBottomLift = ${f(bottomLift)};
const Duration kChromeAnim = Duration(milliseconds: $animMs);
const Curve kChromeCurve = ${curve.code};
const double kMiniFadeStart = ${f(fadeStart)};
const Duration kChromeSwitcher = Duration(milliseconds: $switcherMs);
const double kChromeSwitcherScale = ${f(switcherScale)};
''';
  }
}

/// The curves worth auditioning, as a picker — a slider can't express a curve
/// and typing one on a phone is miserable.
enum ChromeCurve {
  linear('Curves.linear', Curves.linear),
  easeOut('Curves.easeOut', Curves.easeOut),
  easeOutCubic('Curves.easeOutCubic', Curves.easeOutCubic),
  easeOutQuart('Curves.easeOutQuart', Curves.easeOutQuart),
  easeInOutCubic('Curves.easeInOutCubic', Curves.easeInOutCubic),
  fastOutSlowIn('Curves.fastOutSlowIn', Curves.fastOutSlowIn),
  easeOutBack('Curves.easeOutBack', Curves.easeOutBack),
  elasticOut('Curves.elasticOut', Curves.elasticOut);

  const ChromeCurve(this.code, this.value);
  final String code;
  final Curve value;
}

const _prefsKey = 'debug_chrome_tuning_v1';

class ChromeTuningController extends Notifier<ChromeTuning> {
  @override
  ChromeTuning build() {
    _restore();
    return const ChromeTuning();
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null) return;
      state = ChromeTuning.fromJson(
          jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      // Corrupt or absent → ship defaults. Tuning is never load-bearing.
    }
  }

  void update(ChromeTuning next) => state = next;

  /// Persist so the values survive the hot restarts that tuning involves.
  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(state.toJson()));
    } catch (_) {}
  }

  Future<void> reset() async {
    state = const ChromeTuning();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_prefsKey);
    } catch (_) {}
  }
}

final chromeTuningProvider =
    NotifierProvider<ChromeTuningController, ChromeTuning>(
        ChromeTuningController.new);
