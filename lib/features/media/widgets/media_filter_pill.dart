import 'package:flutter/material.dart';

import '../data/local_media_library.dart';

/// Floating segmented pill for filtering the media grid (All / Photos /
/// Videos). Designed to hover over the grid content, centered near the bottom.
class MediaFilterPill extends StatelessWidget {
  const MediaFilterPill({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final MediaFilter value;
  final ValueChanged<MediaFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(999),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in MediaFilter.values)
              _Segment(
                label: f.label,
                selected: f == value,
                onTap: () => onChanged(f),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
