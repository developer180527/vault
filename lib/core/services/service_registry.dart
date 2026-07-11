import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final IconData icon;
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
    required this.selectedIcon,
    this.category = ServiceCategory.tools,
    this.alwaysAvailable = false,
    this.subTabs = const [],
    this.builder,
  }) : assert(subTabs.length > 0 || builder != null,
            'A service needs sub-tabs or a root builder');

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final ServiceCategory category;

  /// Visible even when absent from the manifest (e.g. account/settings), so a
  /// user is never locked out of their own device. Still server-gated for any
  /// privileged action inside.
  final bool alwaysAvailable;

  /// When non-empty the service renders as a tabbed view; otherwise [builder]
  /// provides a single page.
  final List<SubTab> subTabs;
  final WidgetBuilder? builder;
}

/// The full catalog. Populated in app.dart to avoid core → features imports.
final serviceRegistryProvider =
    Provider<List<ServiceDefinition>>((ref) => throw UnimplementedError(
        'serviceRegistryProvider must be overridden at app root'));
