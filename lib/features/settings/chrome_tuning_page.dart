import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/capability/manifest_providers.dart';
import '../../core/debug/chrome_tuning.dart';
import '../../shell/bottom_bar/collapsed_chrome.dart';
import '../../shell/bottom_bar/expanded_chrome.dart';

/// TEMPORARY tuning surface for the mobile bottom chrome.
///
/// Earlier attempts put the controls over the live dock — first a full page
/// that covered it, then a floating card that fought it for space. Both were
/// wrong: you don't need the REAL dock, you need a FAITHFUL one that sits
/// still. So this page renders the actual [ExpandedChrome] / [CollapsedChrome]
/// widgets in a pinned preview strip at the top, and gives the sliders the
/// whole width below. Nothing overlaps, nothing is covered, and the preview is
/// the same code the shell runs — not a mock-up that can drift.
///
/// None of this needs hot reload: the values are runtime state the chrome
/// reads on every build, so it behaves identically in a sideloaded release
/// build. When the layout is settled, **Copy** emits the constants to paste
/// into `shell/bottom_bar/metrics.dart`, after which this page,
/// `core/debug/chrome_tuning.dart` and the Settings entry are deleted.
class ChromeTuningPage extends ConsumerStatefulWidget {
  const ChromeTuningPage({super.key});

  @override
  ConsumerState<ChromeTuningPage> createState() => _ChromeTuningPageState();
}

class _ChromeTuningPageState extends ConsumerState<ChromeTuningPage> {
  // Preview-only. Deliberately NOT in the shared tuning state: forcing these
  // onto the real chrome is what previously pinned the dock collapsed and made
  // it unresponsive. Here they move the preview and nothing else.
  bool _showMini = true;
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    // MiniPlayerPill draws nothing without a real track, so tell it to render a
    // stand-in while this page is open. Safe: the live chrome no longer reads
    // this flag — only the pill does, to decide whether to show the stand-in.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncDemo(_showMini));
  }

  @override
  void dispose() {
    _syncDemo(false);
    super.dispose();
  }

  void _syncDemo(bool on) {
    final ctrl = ref.read(chromeTuningProvider.notifier);
    ctrl.update(ref.read(chromeTuningProvider).copyWith(forceMini: on));
  }

  void _setMini(bool on) {
    setState(() => _showMini = on);
    _syncDemo(on);
  }

  @override
  Widget build(BuildContext context) {
    final tune = ref.watch(chromeTuningProvider);
    final ctrl = ref.read(chromeTuningProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final services = ref.watch(permittedServicesProvider);
    // The dock shows the first few content services, as the shell does.
    final dock = services
        .where((s) => s.id != 'user' && s.id != 'settings')
        .take(4)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bottom chrome'),
        actions: [
          TextButton(
            onPressed: () => ctrl.reset(),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: Column(
        children: [
          // ---- pinned preview ----
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 14),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('PREVIEW',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant)),
                ),
                // The real widgets, at the real width, with the tuned margins.
                Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: tune.sideMargin),
                  child: SizedBox(
                    height: tune.dockHeight,
                    child: _collapsed
                        ? CollapsedChrome(
                            hasTrack: _showMini,
                            onUserPage: false,
                            onExpand: () => setState(() => _collapsed = false),
                            onYou: () {},
                          )
                        : ExpandedChrome(
                            // Rebuild from scratch when the forced state flips,
                            // so the entrance animation replays and can be
                            // judged, not just its end state.
                            key: ValueKey('${_showMini}_${dock.length}'),
                            hasTrack: _showMini,
                            onUserPage: false,
                            dock: dock,
                            currentId: dock.isEmpty ? '' : dock.first.id,
                            onOpen: (_) {},
                            onCollapse: () =>
                                setState(() => _collapsed = true),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _chip(scheme, 'Mini-player', _showMini,
                        () => _setMini(!_showMini)),
                    const SizedBox(width: 8),
                    _chip(scheme, 'Collapsed', _collapsed,
                        () => setState(() => _collapsed = !_collapsed)),
                    const SizedBox(width: 8),
                    _chip(scheme, 'Replay', false, () {
                      // Toggle off/on to watch the squeeze again.
                      _setMini(false);
                      Future<void>.delayed(const Duration(milliseconds: 120),
                          () {
                        if (mounted) _setMini(true);
                      });
                    }),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // ---- sliders, full width ----
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
              children: [
                _head(scheme, 'Mini-player'),
                _slider('Height', tune.miniHeight, 28, 72,
                    (v) => ctrl.update(tune.copyWith(miniHeight: v)),
                    unit: 'pt'),
                _slider('Width share of row', tune.miniFraction, 0.2, 0.85,
                    (v) => ctrl.update(tune.copyWith(miniFraction: v)),
                    pct: true),

                _head(scheme, 'Dock & You'),
                _slider('Dock height', tune.dockHeight, 44, 96,
                    (v) => ctrl.update(tune.copyWith(dockHeight: v)),
                    unit: 'pt'),
                _slider('You — idle', tune.youExpanded, 40, 96,
                    (v) => ctrl.update(tune.copyWith(youExpanded: v)),
                    unit: 'pt'),
                _slider('You — playing', tune.youShrunk, 32, 88,
                    (v) => ctrl.update(tune.copyWith(youShrunk: v)),
                    unit: 'pt'),

                _head(scheme, 'Spacing'),
                _slider('Gap between pills', tune.gap, 0, 24,
                    (v) => ctrl.update(tune.copyWith(gap: v)), unit: 'pt'),
                _slider('Side margin', tune.sideMargin, 0, 32,
                    (v) => ctrl.update(tune.copyWith(sideMargin: v)),
                    unit: 'pt'),
                _slider('Lift off bottom edge', tune.bottomLift, 0, 28,
                    (v) => ctrl.update(tune.copyWith(bottomLift: v)),
                    unit: 'pt'),

                _head(scheme, 'Animation'),
                _slider('Squeeze duration', tune.animMs.toDouble(), 120, 900,
                    (v) => ctrl.update(tune.copyWith(animMs: v.round())),
                    unit: 'ms'),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Curve')),
                      DropdownButton<ChromeCurve>(
                        value: tune.curve,
                        onChanged: (c) => c == null
                            ? null
                            : ctrl.update(tune.copyWith(curve: c)),
                        items: [
                          for (final c in ChromeCurve.values)
                            DropdownMenuItem(
                              value: c,
                              child: Text(c.code.replaceFirst('Curves.', '')),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                _slider('Pill fades in at', tune.fadeStart, 0, 0.8,
                    (v) => ctrl.update(tune.copyWith(fadeStart: v)),
                    pct: true),
                _slider('Collapse cross-fade', tune.switcherMs.toDouble(), 100,
                    600,
                    (v) => ctrl.update(tune.copyWith(switcherMs: v.round())),
                    unit: 'ms'),
                _slider('Collapse scale-in', tune.switcherScale, 0.8, 1.0,
                    (v) => ctrl.update(tune.copyWith(switcherScale: v))),

                const SizedBox(height: 22),
                FilledButton.icon(
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy constants'),
                  onPressed: () async {
                    await ctrl.save();
                    await Clipboard.setData(
                        ClipboardData(text: tune.toDartCode()));
                    if (context.mounted) _showCode(tune.toDartCode());
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
          ColorScheme scheme, String label, bool on, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: on ? scheme.primary : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: on ? scheme.onPrimary : scheme.onSurfaceVariant)),
        ),
      );

  Widget _head(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: scheme.primary)),
      );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String? unit,
    bool pct = false,
  }) {
    final shown =
        pct ? '${(value * 100).round()}%' : '${value.round()}${unit ?? ''}';
    return Row(
      children: [
        SizedBox(
            width: 128,
            child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(shown,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  void _showCode(String code) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Copied — paste this back'),
          content: SingleChildScrollView(
            child: SelectableText(code,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done')),
          ],
        ),
      );
}
