import 'package:flutter/material.dart';

/// A background-LESS mobile header: the service title (bold) and its action
/// buttons float directly over the content, which scrolls full-bleed beneath
/// them. No bar fill, no blur strip — the chrome reads as objects on the page,
/// not a separate toolbar layer. Legibility comes from the title's soft halo
/// and the actions' own glass chips (see [ActionBar] `floating`), so text and
/// icons stay readable over bright or busy content.
///
/// Requires `extendBodyBehindAppBar: true` on the enclosing Scaffold.
class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FloatingAppBar({super.key, required this.title, this.actions});

  final Widget title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      // Bold, large service title floating over the page. The halo (a blur in
      // the surface color) keeps it legible over bright photos without a bar.
      titleTextStyle: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        color: scheme.onSurface,
        shadows: [
          Shadow(color: scheme.surface.withValues(alpha: 0.65), blurRadius: 12),
          Shadow(color: scheme.surface.withValues(alpha: 0.45), blurRadius: 4),
        ],
      ),
      title: title,
      actions: actions,
    );
  }
}
