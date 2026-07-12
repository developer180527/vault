import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/log_types.dart';
import '../../core/logging/vault_log.dart';

/// In-app log viewer over the in-memory ring buffer. Live-updates as records
/// arrive, filters by minimum level, and copies the buffer for a bug report.
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  LogLevel _minLevel = LogLevel.trace;

  @override
  Widget build(BuildContext context) {
    final memory = VaultLog.memory;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          PopupMenuButton<LogLevel>(
            tooltip: 'Minimum level',
            icon: const Icon(Icons.filter_list),
            initialValue: _minLevel,
            onSelected: (l) => setState(() => _minLevel = l),
            itemBuilder: (_) => [
              for (final l in LogLevel.values)
                PopupMenuItem(value: l, child: Text(l.label)),
            ],
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all),
            onPressed: memory == null
                ? null
                : () async {
                    await Clipboard.setData(
                        ClipboardData(text: memory.export()));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Logs copied')));
                    }
                  },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: memory?.clear,
          ),
        ],
      ),
      body: memory == null
          ? const Center(child: Text('Logging not initialized'))
          : ListenableBuilder(
              listenable: memory,
              builder: (context, _) {
                final records = [
                  for (final r in memory.records.reversed)
                    if (r.level.index >= _minLevel.index) r,
                ];
                if (records.isEmpty) {
                  return const Center(child: Text('No log entries'));
                }
                return ListView.separated(
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _LogTile(record: records[i]),
                );
              },
            ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.record});

  final LogRecord record;

  Color _color(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (record.level) {
      LogLevel.trace || LogLevel.debug => scheme.outline,
      LogLevel.info => scheme.primary,
      LogLevel.warn => Colors.orange,
      LogLevel.error || LogLevel.fatal => scheme.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    final t = record.time;
    final time =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return ListTile(
      dense: true,
      leading: Text(record.level.glyph,
          style: TextStyle(color: color, fontSize: 18)),
      title: Text(record.message,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
      subtitle: Text(
        [
          time,
          record.tag,
          if (record.fields.isNotEmpty) record.fields.toString(),
          if (record.error != null) 'error: ${record.error}',
        ].join('  ·  '),
        style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
      ),
      trailing: Text(record.level.label,
          style: TextStyle(color: color, fontSize: 10)),
    );
  }
}
