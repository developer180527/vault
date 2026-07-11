import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/platform_info.dart';
import '../core/services/service_registry.dart';
import 'desktop_shell.dart';
import 'mobile_shell.dart';

/// Width at which non-desktop platforms (web, tablets) switch from the mobile
/// bottom-bar shell to the desktop sidebar shell. Native desktop OSes always
/// use the sidebar regardless of window width.
const kDesktopBreakpoint = 840.0;

/// Whether to use the sidebar (desktop) shell. Native desktop always does;
/// web and mobile decide by available width.
bool useDesktopShell(double width) =>
    isDesktopPlatform || width >= kDesktopBreakpoint;

/// Exposes the current form factor to descendants so feature pages can adapt
/// (e.g. sub-tabs render as a dropdown on desktop, a TabBar on mobile)
/// without re-deriving breakpoints.
class FormFactor extends InheritedWidget {
  const FormFactor({super.key, required this.isDesktop, required super.child});

  final bool isDesktop;

  static bool isDesktopOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FormFactor>()
          ?.isDesktop ??
      false;

  @override
  bool updateShouldNotify(FormFactor oldWidget) =>
      oldWidget.isDesktop != isDesktop;
}

class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({
    super.key,
    required this.shell,
    required this.services,
  });

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final isDesktop = useDesktopShell(constraints.maxWidth);
      return FormFactor(
        isDesktop: isDesktop,
        child: isDesktop
            ? DesktopShell(shell: shell, services: services)
            : MobileShell(shell: shell, services: services),
      );
    });
  }
}
