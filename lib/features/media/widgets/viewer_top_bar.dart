import 'package:flutter/material.dart';

import '../../../core/actions/vault_action.dart';
import '../../../core/platform/platform_info.dart';
import '../../../shell/widgets/action_bar.dart';

/// Standardized chrome for fullscreen media surfaces (the viewer today, media
/// editing later): a translucent gradient bar with a close button, a title,
/// and a [VaultAction] slot where per-media tools (edit / crop / share / info)
/// will land.
///
/// Fullscreen surfaces cover the whole frameless window on desktop, and on
/// macOS the traffic lights float over our content at the top-left — so the
/// close button is inset past them instead of hiding underneath.
class ViewerTopBar extends StatelessWidget implements PreferredSizeWidget {
  const ViewerTopBar({
    super.key,
    required this.title,
    this.actions = const [],
  });

  final String title;

  /// Future media tools (edit, share, info…) render here via [ActionBar].
  final List<VaultAction> actions;

  static const double _height = 48;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: _height,
          child: Row(
            children: [
              // Clear the macOS traffic lights (same inset as the title bar).
              SizedBox(width: isMacOS ? 78 : 4),
              IconButton(
                tooltip: 'Close',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              ActionBar(actions: actions),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
