import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Translucent toolbar for the mobile shell: a backdrop blur plus a vertical
/// surface gradient, so scrolled content visibly passes *beneath* the bar
/// like a separate layer. Pure Flutter — identical on iOS and Android (this
/// is deliberately NOT platform-gated).
///
/// Requires `extendBodyBehindAppBar: true` on the enclosing Scaffold; pages
/// with default-padded scrollables pick the inset up automatically from
/// MediaQuery, pages with explicit padding add `MediaQuery.paddingOf` in.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({super.key, required this.title, this.actions});

  final Widget title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return AppBar(
      title: title,
      actions: actions,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      // flexibleSpace spans the status bar too, so the glass covers the full
      // system chrome area, not just the toolbar strip.
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  surface.withValues(alpha: 0.85),
                  surface.withValues(alpha: 0.55),
                ],
              ),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
