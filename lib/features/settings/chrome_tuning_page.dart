import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/debug/chrome_tuning.dart';

/// TEMPORARY tuning panel for the mobile bottom chrome.
///
/// The point is to collapse the "describe it → guess → rebuild → look again"
/// loop into one sitting: the dock and mini-player stay visible at the bottom
/// of this very page, so every slider moves the real thing under your thumb.
/// When it looks right, **Copy constants** puts the settled values on the
/// clipboard as Dart — paste them back and they get hardcoded into
/// `shell/bottom_bar/metrics.dart`, after which this page is deleted.
///
/// Values persist locally so a hot restart mid-tune doesn't lose the session.
class ChromeTuningPage extends ConsumerWidget {
  const ChromeTuningPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tune = ref.watch(chromeTuningProvider);
    final ctrl = ref.read(chromeTuningProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bottom chrome tuning'),
        actions: [
          IconButton(
            tooltip: 'Reset to shipped defaults',
            icon: const Icon(Icons.restart_alt),
            onPressed: () async {
              await ctrl.reset();
              if (context.mounted) _toast(context, 'Reset to defaults');
            },
          ),
        ],
      ),
      body: ListView(
        // Clear the floating chrome, which stays visible below so you can see
        // what you're tuning. That's the whole point of this page.
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
        children: [
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.science_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'The dock below updates live. Tune it, then Copy '
                      'constants and send them over to be hardcoded.',
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          _section(context, 'Preview state'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Show mini-player'),
            subtitle: const Text('Fake a playing track so you can tune it'),
            value: tune.forceMini,
            onChanged: (v) => ctrl.update(tune.copyWith(forceMini: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Collapsed dock'),
            subtitle: const Text('The tucked-away 4-box state'),
            value: tune.forceCollapsed,
            onChanged: (v) => ctrl.update(tune.copyWith(forceCollapsed: v)),
          ),

          _section(context, 'Mini-player'),
          _slider(context, 'Height (breadth)', tune.miniHeight, 28, 72,
              (v) => ctrl.update(tune.copyWith(miniHeight: v)), unit: 'pt'),
          _slider(context, 'Width share of row (length)', tune.miniFraction,
              0.25, 0.8, (v) => ctrl.update(tune.copyWith(miniFraction: v)),
              pct: true),

          _section(context, 'Dock & You'),
          _slider(context, 'Dock height', tune.dockHeight, 44, 96,
              (v) => ctrl.update(tune.copyWith(dockHeight: v)), unit: 'pt'),
          _slider(context, 'You circle — idle', tune.youExpanded, 40, 96,
              (v) => ctrl.update(tune.copyWith(youExpanded: v)), unit: 'pt'),
          _slider(context, 'You circle — playing', tune.youShrunk, 32, 88,
              (v) => ctrl.update(tune.copyWith(youShrunk: v)), unit: 'pt'),

          _section(context, 'Spacing'),
          _slider(context, 'Gap between pills', tune.gap, 0, 24,
              (v) => ctrl.update(tune.copyWith(gap: v)), unit: 'pt'),
          _slider(context, 'Side margin', tune.sideMargin, 0, 32,
              (v) => ctrl.update(tune.copyWith(sideMargin: v)), unit: 'pt'),
          _slider(context, 'Lift off bottom edge', tune.bottomLift, 0, 28,
              (v) => ctrl.update(tune.copyWith(bottomLift: v)), unit: 'pt'),

          _section(context, 'Animation'),
          _slider(context, 'Squeeze duration', tune.animMs.toDouble(), 120, 900,
              (v) => ctrl.update(tune.copyWith(animMs: v.round())),
              unit: 'ms'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Curve'),
            trailing: DropdownButton<ChromeCurve>(
              value: tune.curve,
              onChanged: (c) =>
                  c == null ? null : ctrl.update(tune.copyWith(curve: c)),
              items: [
                for (final c in ChromeCurve.values)
                  DropdownMenuItem(
                    value: c,
                    child: Text(c.code.replaceFirst('Curves.', '')),
                  ),
              ],
            ),
          ),
          _slider(context, 'Mini-player fades in at', tune.fadeStart, 0, 0.8,
              (v) => ctrl.update(tune.copyWith(fadeStart: v)), pct: true),
          _slider(context, 'Collapse cross-fade', tune.switcherMs.toDouble(),
              100, 600, (v) => ctrl.update(tune.copyWith(switcherMs: v.round())),
              unit: 'ms'),
          _slider(context, 'Collapse scale-in', tune.switcherScale, 0.8, 1.0,
              (v) => ctrl.update(tune.copyWith(switcherScale: v))),

          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy constants'),
                  onPressed: () async {
                    await ctrl.save();
                    await Clipboard.setData(
                        ClipboardData(text: tune.toDartCode()));
                    if (context.mounted) {
                      _showCode(context, tune.toDartCode());
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save'),
                onPressed: () async {
                  await ctrl.save();
                  if (context.mounted) _toast(context, 'Saved on this device');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  static void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));

  /// Also shown on screen, not just copied — clipboard transfer off a phone is
  /// unreliable, and this way the values can be read out or screenshotted.
  static void _showCode(BuildContext context, String code) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copied — paste this back'),
        content: SingleChildScrollView(
          child: SelectableText(code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  static Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 2),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  static Widget _slider(
    BuildContext context,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String? unit,
    bool pct = false,
  }) {
    final shown = pct
        ? '${(value * 100).round()}%'
        : '${value.round()}${unit ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
              Text(shown,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          SliderTheme(
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
        ],
      ),
    );
  }
}
