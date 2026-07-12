import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/platform_info.dart';
import '../core/services/service_registry.dart';
import 'command_palette.dart';
import 'desktop_shell.dart';
import 'mobile_shell.dart';

/// Width at which large-screen devices (web, tablets) switch from the mobile
/// bottom-bar shell to the desktop sidebar shell.
const kDesktopBreakpoint = 840.0;

/// Below this shortest-side, a device is a phone and always uses the mobile
/// shell — even in landscape (where its width can exceed [kDesktopBreakpoint]).
const kPhoneShortestSide = 600.0;

/// Whether to use the sidebar (desktop) shell.
/// - Native desktop: always.
/// - Phone (shortest side < 600): never — bottom-nav in both orientations.
/// - Tablet / web: by available width.
bool useDesktopShell(BuildContext context, double width) {
  if (isDesktopPlatform) return true;
  if (MediaQuery.sizeOf(context).shortestSide < kPhoneShortestSide) {
    return false;
  }
  return width >= kDesktopBreakpoint;
}

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
      final isDesktop = useDesktopShell(context, constraints.maxWidth);
      // Cmd/Ctrl-K opens the command palette app-wide. Placed here so the
      // dialog resolves against the router's navigator/overlay.
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              showCommandPalette(context),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
              showCommandPalette(context),
        },
        child: Focus(
          autofocus: true,
          child: FormFactor(
            isDesktop: isDesktop,
            child: isDesktop
                ? DesktopShell(shell: shell, services: services)
                : MobileShell(shell: shell, services: services),
          ),
        ),
      );
    });
  }
}
