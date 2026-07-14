import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/design/adaptive_icons.dart';

/// A single invokable command. The unit that replaced the menu bar: the same
/// action object is rendered in the content toolbar, the right-click/long-press
/// context menu, AND the Cmd-K command palette — and it works identically on
/// desktop and mobile. Actions read whatever provider state they need at invoke
/// time (e.g. the current folder), so they don't need to be re-created when that
/// state changes.
class VaultAction {
  const VaultAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onInvoke,
    this.shortcut,
    this.isDestructive = false,
    this.isEnabled,
  });

  final String id;
  final String label;

  /// Semantic icon — SF Symbol on Apple platforms, Material glyph elsewhere.
  final AdaptiveIconData icon;

  /// Optional keyboard accelerator, shown in the palette and active app-wide.
  final SingleActivator? shortcut;

  final bool isDestructive;

  /// Optional gate (e.g. capability check). When it returns false the action is
  /// hidden from the toolbar/menu and disabled in the palette.
  final bool Function(WidgetRef ref)? isEnabled;

  final void Function(BuildContext context, WidgetRef ref) onInvoke;

  bool enabled(WidgetRef ref) => isEnabled?.call(ref) ?? true;
}

/// Actions a feature contributes for a given item (e.g. a file row), built on
/// demand because they depend on which item was targeted.
typedef ItemActionsBuilder<T> = List<VaultAction> Function(T item);
