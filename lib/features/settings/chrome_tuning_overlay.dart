import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/debug/chrome_tuning.dart';
import '../../shell/bottom_bar/metrics.dart';

/// TEMPORARY live-tuning HUD for the mobile bottom chrome.
///
/// It is an OVERLAY, not a page, and that is the whole point: a pushed route
/// covered the dock it was meant to tune, so every slider moved something
/// invisible. This floats above the app, can be dragged out of the way, and
/// lets touches outside it through — so the dock stays visible AND usable
/// while you tune it.
///
/// Nothing here depends on hot reload. The values are ordinary runtime state
/// that the chrome reads on every build, so this works exactly the same in a
/// sideloaded release build as in debug.
///
/// When the layout is settled, **Copy** emits the constants to paste into
/// `shell/bottom_bar/metrics.dart`, after which this file, `chrome_tuning.dart`
/// and the Settings entry all get deleted.
void showChromeTuningOverlay(BuildContext context) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TuningHud(onClose: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _TuningHud extends ConsumerStatefulWidget {
  const _TuningHud({required this.onClose});
  final VoidCallback onClose;

  @override
  ConsumerState<_TuningHud> createState() => _TuningHudState();
}

class _TuningHudState extends ConsumerState<_TuningHud> {
  Offset _pos = const Offset(12, 80);
  bool _minimised = false;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = media.size.width - 24;

    // Stack fills the screen but only the card takes hits — everything else is
    // explicitly not hit-testable, so the dock below stays tappable.
    return Stack(
      children: [
        Positioned(
          left: _pos.dx,
          top: _pos.dy,
          width: width,
          child: Material(
            elevation: 12,
            borderRadius: BorderRadius.circular(16),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.97),
            child: ConstrainedBox(
              // Capped so the bottom chrome is never covered — leave the lower
              // third of the screen clear.
              constraints: BoxConstraints(
                maxHeight: media.size.height * 0.52,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(scheme),
                  if (!_minimised)
                    Flexible(child: _body(scheme)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(ColorScheme scheme) => GestureDetector(
        // Drag the card anywhere — the thing you're tuning may be underneath.
        onPanUpdate: (d) => setState(() => _pos += d.delta),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(
            children: [
              Icon(Icons.drag_indicator,
                  size: 18, color: scheme.onPrimaryContainer),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Chrome tuning',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(_minimised ? Icons.expand_more : Icons.expand_less,
                    size: 20, color: scheme.onPrimaryContainer),
                onPressed: () => setState(() => _minimised = !_minimised),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close,
                    size: 20, color: scheme.onPrimaryContainer),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      );

  Widget _body(ColorScheme scheme) {
    final tune = ref.watch(chromeTuningProvider);
    final ctrl = ref.read(chromeTuningProvider.notifier);

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      children: [
        Row(
          children: [
            Expanded(
              child: _toggle(scheme, 'Mini-player', tune.forceMini,
                  (v) => ctrl.update(tune.copyWith(forceMini: v))),
            ),
            const SizedBox(width: 8),
            Expanded(
              // Drives the REAL collapse state rather than overriding it, so
              // the dock stays interactive.
              child: _toggle(scheme, 'Collapsed', ref.watch(dockCollapsedProvider),
                  (v) => ref.read(dockCollapsedProvider.notifier).set(v)),
            ),
          ],
        ),
        const Divider(height: 18),
        _slider('Mini height', tune.miniHeight, 28, 72,
            (v) => ctrl.update(tune.copyWith(miniHeight: v)), unit: 'pt'),
        _slider('Mini width share', tune.miniFraction, 0.2, 0.85,
            (v) => ctrl.update(tune.copyWith(miniFraction: v)), pct: true),
        _slider('Dock height', tune.dockHeight, 44, 96,
            (v) => ctrl.update(tune.copyWith(dockHeight: v)), unit: 'pt'),
        _slider('You — idle', tune.youExpanded, 40, 96,
            (v) => ctrl.update(tune.copyWith(youExpanded: v)), unit: 'pt'),
        _slider('You — playing', tune.youShrunk, 32, 88,
            (v) => ctrl.update(tune.copyWith(youShrunk: v)), unit: 'pt'),
        _slider('Gap', tune.gap, 0, 24,
            (v) => ctrl.update(tune.copyWith(gap: v)), unit: 'pt'),
        _slider('Side margin', tune.sideMargin, 0, 32,
            (v) => ctrl.update(tune.copyWith(sideMargin: v)), unit: 'pt'),
        _slider('Bottom lift', tune.bottomLift, 0, 28,
            (v) => ctrl.update(tune.copyWith(bottomLift: v)), unit: 'pt'),
        const Divider(height: 18),
        _slider('Squeeze ms', tune.animMs.toDouble(), 120, 900,
            (v) => ctrl.update(tune.copyWith(animMs: v.round())), unit: 'ms'),
        Row(
          children: [
            const Expanded(child: Text('Curve', style: TextStyle(fontSize: 12))),
            DropdownButton<ChromeCurve>(
              isDense: true,
              value: tune.curve,
              onChanged: (c) =>
                  c == null ? null : ctrl.update(tune.copyWith(curve: c)),
              items: [
                for (final c in ChromeCurve.values)
                  DropdownMenuItem(
                    value: c,
                    child: Text(c.code.replaceFirst('Curves.', ''),
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
        _slider('Pill fades in at', tune.fadeStart, 0, 0.8,
            (v) => ctrl.update(tune.copyWith(fadeStart: v)), pct: true),
        _slider('Collapse ms', tune.switcherMs.toDouble(), 100, 600,
            (v) => ctrl.update(tune.copyWith(switcherMs: v.round())),
            unit: 'ms'),
        _slider('Collapse scale', tune.switcherScale, 0.8, 1.0,
            (v) => ctrl.update(tune.copyWith(switcherScale: v))),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: const Text('Copy', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  await ctrl.save();
                  await Clipboard.setData(
                      ClipboardData(text: tune.toDartCode()));
                  if (mounted) _showCode(tune.toDartCode());
                },
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact),
              onPressed: () => ctrl.reset(),
              child: const Text('Reset', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _toggle(
          ColorScheme scheme, String label, bool value, ValueChanged<bool> on) =>
      InkWell(
        onTap: () => on(!value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: value ? scheme.primary : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(value ? Icons.check : Icons.remove,
                  size: 14,
                  color: value ? scheme.onPrimary : scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          value ? scheme.onPrimary : scheme.onSurfaceVariant)),
            ],
          ),
        ),
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
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          SizedBox(
              width: 96,
              child: Text(label, style: const TextStyle(fontSize: 11.5))),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
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
              width: 42,
              child: Text(shown,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11))),
        ],
      ),
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
