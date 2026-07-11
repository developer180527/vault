import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tasks/background_tasks.dart';

/// Shell chrome button showing background work (uploads, sync, transcode…).
/// Idle: a quiet cloud-done icon. Busy: progress ring + task count.
/// Tapping opens a popup listing every task.
class TaskStatusButton extends ConsumerWidget {
  const TaskStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(backgroundTasksProvider);
    final theme = Theme.of(context);

    final determinate =
        tasks.where((t) => t.progress != null).map((t) => t.progress!);
    final double? overall = tasks.isEmpty
        ? null
        : determinate.isEmpty
            ? null
            : determinate.reduce((a, b) => a + b) / determinate.length;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 8),
      menuChildren: [
        if (tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No background activity'),
          )
        else
          for (final task in tasks)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: 260,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.label, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: task.progress),
                  ],
                ),
              ),
            ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tasks.isEmpty
            ? 'Up to date'
            : '${tasks.length} task${tasks.length == 1 ? '' : 's'} running',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: tasks.isEmpty
            ? const Icon(Icons.cloud_done_outlined)
            : Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child:
                        CircularProgressIndicator(value: overall, strokeWidth: 2.5),
                  ),
                  Text('${tasks.length}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
      ),
    );
  }
}
