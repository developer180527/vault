import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:markdown_widget/markdown_widget.dart';
import 'package:pdfrx/pdfrx.dart';

/// The kinds of document this viewer can render. Routed by file extension.
enum DocKind { pdf, markdown, code, text, unsupported }

DocKind docKindFor(String name) {
  final ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  if (ext == 'pdf') return DocKind.pdf;
  if (ext == 'md' || ext == 'markdown') return DocKind.markdown;
  const code = {
    'dart', 'go', 'js', 'ts', 'jsx', 'tsx', 'py', 'rb', 'rs', 'java', 'kt',
    'swift', 'c', 'h', 'cpp', 'cc', 'hpp', 'cs', 'php', 'sh', 'bash', 'zsh',
    'sql', 'html', 'css', 'scss', 'json', 'yaml', 'yml', 'toml', 'xml',
    'ini', 'conf', 'gradle', 'lua', 'r', 'pl', 'vue', 'svelte', 'graphql',
  };
  const text = {'txt', 'text', 'log', 'csv', 'tsv', 'env', 'gitignore', 'lock'};
  if (code.contains(ext)) return DocKind.code;
  if (text.contains(ext) || ext.isEmpty) return DocKind.text;
  return DocKind.unsupported;
}

/// Whether a file has a viewer (drives whether Files offers "open").
bool isViewableDocument(String name) => docKindFor(name) != DocKind.unsupported;

/// Opens the appropriate document viewer full-screen over the shell.
Future<void> openDocument(
  BuildContext context, {
  required String name,
  required Uri uri,
  required Map<String, String> headers,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => DocumentViewerPage(name: name, uri: uri, headers: headers),
    ),
  );
}

/// Full-screen document viewer: PDFs via pdfrx (pinch-zoom, paged), Markdown
/// rendered, code/text in a selectable monospace view with line numbers.
class DocumentViewerPage extends StatelessWidget {
  const DocumentViewerPage({
    super.key,
    required this.name,
    required this.uri,
    required this.headers,
  });

  final String name;
  final Uri uri;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final kind = docKindFor(name);
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: switch (kind) {
        DocKind.pdf => PdfViewer.uri(
            uri,
            headers: headers,
            params: const PdfViewerParams(
              backgroundColor: Color(0xFF1A1A1A),
              margin: 8,
            ),
          ),
        _ => _TextBased(name: name, uri: uri, headers: headers, kind: kind),
      },
    );
  }
}

/// Fetches the file as text and renders it (markdown, code, or plain).
class _TextBased extends StatefulWidget {
  const _TextBased({
    required this.name,
    required this.uri,
    required this.headers,
    required this.kind,
  });

  final String name;
  final Uri uri;
  final Map<String, String> headers;
  final DocKind kind;

  @override
  State<_TextBased> createState() => _TextBasedState();
}

class _TextBasedState extends State<_TextBased> {
  Future<String>? _content;
  bool _wrap = true;

  @override
  void initState() {
    super.initState();
    _content = _load();
  }

  Future<String> _load() async {
    final res = await http.get(widget.uri, headers: widget.headers);
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    var text = utf8.decode(res.bodyBytes, allowMalformed: true);
    // Pretty-print JSON so it's actually readable.
    if (widget.name.toLowerCase().endsWith('.json')) {
      try {
        text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      } catch (_) {
        // Not valid JSON — show it raw.
      }
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _content,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Could not open: ${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final text = snap.data!;
        if (widget.kind == DocKind.markdown) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MarkdownBlock(
              data: text,
              config: Theme.of(context).brightness == Brightness.dark
                  ? MarkdownConfig.darkConfig
                  : MarkdownConfig.defaultConfig,
            ),
          );
        }
        return _CodeView(text: text, wrap: _wrap, onToggleWrap: () {
          setState(() => _wrap = !_wrap);
        });
      },
    );
  }
}

/// Monospace, line-numbered, selectable code/text view with a wrap toggle and
/// copy button.
class _CodeView extends StatelessWidget {
  const _CodeView({
    required this.text,
    required this.wrap,
    required this.onToggleWrap,
  });

  final String text;
  final bool wrap;
  final VoidCallback onToggleWrap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = text.split('\n');
    final gutterWidth = '${lines.length}'.length * 9.0 + 16;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5);

    Widget body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line-number gutter.
          SizedBox(
            width: gutterWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < lines.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('${i + 1}',
                        style: mono.copyWith(color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SelectableText(text, style: mono),
          ),
        ],
      ),
    );

    // Wrap mode keeps lines within width; no-wrap scrolls horizontally.
    Widget scroller = wrap
        ? SingleChildScrollView(child: body)
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.sizeOf(context).width,
              ),
              child: SingleChildScrollView(child: body),
            ),
          );

    return Stack(
      children: [
        scroller,
        Positioned(
          right: 12,
          bottom: 12,
          child: Row(
            children: [
              _fab(context, wrap ? Icons.wrap_text : Icons.notes,
                  'Toggle wrap', onToggleWrap),
              const SizedBox(width: 8),
              _fab(context, Icons.copy, 'Copy all', () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fab(BuildContext context, IconData icon, String tip, VoidCallback f) {
    return FloatingActionButton.small(
      heroTag: tip,
      tooltip: tip,
      onPressed: f,
      child: Icon(icon),
    );
  }
}
