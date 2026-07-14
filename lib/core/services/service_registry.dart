import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actions/vault_action.dart';
import '../platform/design/adaptive_icons.dart';

/// Broad grouping for organizing services in the desktop sidebar and the
/// mobile Services hub once there are many of them.
enum ServiceCategory {
  media('Media'),
  files('Files'),
  tools('Tools'),
  system('System');

  const ServiceCategory(this.label);
  final String label;
}

/// One second-level tab inside a service (e.g. Media → Photos).
class SubTab {
  const SubTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String label;
  final AdaptiveIconData icon;
  final WidgetBuilder builder;
}

/// A top-level service in the shell. This is the *UI/route* declaration only —
/// whether a user actually sees it is decided by the server capability manifest
/// (see [permittedServicesProvider]), never by this object. Adding a service is
/// one registry entry; visibility and permissions come from the server.
class ServiceDefinition {
  const ServiceDefinition({
    required this.id,
    required this.label,
    required this.icon,
    this.category = ServiceCategory.tools,
    this.alwaysAvailable = false,
    this.subTabs = const [],
    this.actions = const [],
    this.toolbarLeading,
    this.statusBar,
    this.builder,
  }) : assert(subTabs.length > 0 || builder != null,
            'A service needs sub-tabs or a root builder');

  final String id;
  final String label;

  /// Semantic icon resolving to SF Symbols on Apple platforms, Material
  /// elsewhere (with filled selected variants for navigation).
  final AdaptiveIconData icon;
  final ServiceCategory category;

  /// Visible even when absent from the manifest (e.g. account/settings), so a
  /// user is never locked out of their own device. Still server-gated for any
  /// privileged action inside.
  final bool alwaysAvailable;

  /// When non-empty the service renders as a tabbed view; otherwise [builder]
  /// provides a single page.
  final List<SubTab> subTabs;

  /// Commands this service contributes — shown as buttons in the content
  /// toolbar and listed in the Cmd-K palette. These replace what used to be
  /// the File/View menus, now living contextually per service.
  final List<VaultAction> actions;

  /// Optional widget for the left of the desktop content toolbar — e.g. the
  /// file browser's back/forward + current-directory name. Null → nothing.
  final WidgetBuilder? toolbarLeading;

  /// Optional per-tab status/control shown in the top-right status slot (where
  /// the background-work cloud used to be) — e.g. the Media filter dropdown.
  final WidgetBuilder? statusBar;

  final WidgetBuilder? builder;
}

/// The full catalog. Populated in app.dart to avoid core → features imports.
final serviceRegistryProvider =
    Provider<List<ServiceDefinition>>((ref) => throw UnimplementedError(
        'serviceRegistryProvider must be overridden at app root'));
