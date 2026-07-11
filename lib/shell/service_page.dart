import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/services/service_registry.dart';
import 'adaptive_shell.dart';

/// Renders one service from its definition. On desktop every service gets a
/// content toolbar (back/forward on the left, sub-tab selector on the right,
/// like the mockup); tabbed services switch panes via the selector. On mobile
/// sub-tabs render as a swipeable TabBar and single-page services fill the body.
class ServicePage extends StatefulWidget {
  const ServicePage({super.key, required this.service});

  final ServiceDefinition service;

  @override
  State<ServicePage> createState() => _ServicePageState();
}

class _ServicePageState extends State<ServicePage>
    with TickerProviderStateMixin {
  TabController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.service.subTabs.isNotEmpty) {
      _controller =
          TabController(length: widget.service.subTabs.length, vsync: this);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = FormFactor.isDesktopOf(context);
    return isDesktop ? _buildDesktop(context) : _buildMobile();
  }

  Widget _buildDesktop(BuildContext context) {
    final tabs = widget.service.subTabs;
    return AnimatedBuilder(
      animation: _controller ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) {
        final body = tabs.isEmpty
            ? widget.service.builder!(context)
            : tabs[_controller!.index].builder(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ContentToolbar(
              selector: tabs.isEmpty ? null : _SubTabSelector(
                tabs: tabs,
                index: _controller!.index,
                onSelected: (i) => setState(() => _controller!.index = i),
              ),
            ),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  Widget _buildMobile() {
    final tabs = widget.service.subTabs;
    if (tabs.isEmpty) return widget.service.builder!(context);
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _controller,
            isScrollable: tabs.length > 3,
            tabAlignment: tabs.length > 3 ? TabAlignment.start : null,
            tabs: [for (final t in tabs) Tab(text: t.label)],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: [for (final t in tabs) t.builder(context)],
          ),
        ),
      ],
    );
  }
}

/// Desktop content header: browser-style back/forward on the left, an optional
/// per-service control slot (the sub-tab selector) on the right.
class _ContentToolbar extends StatelessWidget {
  const _ContentToolbar({this.selector});

  final Widget? selector;

  @override
  Widget build(BuildContext context) {
    final canBack = GoRouter.of(context).canPop();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 6),
      child: Row(
        children: [
          _NavArrow(
            icon: Icons.arrow_back,
            enabled: canBack,
            onPressed: canBack ? () => context.pop() : null,
          ),
          const SizedBox(width: 4),
          // Forward has no history stack yet; disabled until detail routes push.
          const _NavArrow(icon: Icons.arrow_forward, enabled: false),
          const Spacer(),
          ?selector,
        ],
      ),
    );
  }
}

class _NavArrow extends StatelessWidget {
  const _NavArrow(
      {required this.icon, required this.enabled, this.onPressed});

  final IconData icon;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
    );
  }
}

class _SubTabSelector extends StatelessWidget {
  const _SubTabSelector(
      {required this.tabs, required this.index, required this.onSelected});

  final List<SubTab> tabs;
  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final current = tabs[index];
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (var i = 0; i < tabs.length; i++)
          MenuItemButton(
            leadingIcon: Icon(tabs[i].icon, size: 18),
            onPressed: () => onSelected(i),
            child: Text(tabs[i].label),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(current.icon, size: 18),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current.label),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}
