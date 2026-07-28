import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client/vault_client.dart';
import '../../core/models/server_movie.dart';
import '../../core/models/server_track.dart';
import '../media/data/server_music.dart';
import '../movies/data/server_movies.dart';

/// Opens the metadata editor for a catalog track.
Future<void> openTrackEditor(BuildContext context, ServerTrack track) =>
    showDialog<void>(
      context: context,
      builder: (_) => _EditDialog.track(track),
    );

/// Opens the metadata editor for a movie.
Future<void> openMovieEditor(BuildContext context, ServerMovie movie) =>
    showDialog<void>(
      context: context,
      builder: (_) => _EditDialog.movie(movie),
    );

/// Metadata + artwork editor. Edits are stored in the DB (they survive
/// rescans) and artwork is stored as an override beside the media, so nothing
/// here ever rewrites the library file itself.
class _EditDialog extends ConsumerStatefulWidget {
  const _EditDialog.track(ServerTrack this.track) : movie = null;
  const _EditDialog.movie(ServerMovie this.movie) : track = null;

  final ServerTrack? track;
  final ServerMovie? movie;

  bool get isTrack => track != null;
  String get id => track?.id ?? movie!.id;

  @override
  ConsumerState<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends ConsumerState<_EditDialog> {
  late final Map<String, TextEditingController> _c;
  bool _saving = false;
  String? _error;
  File? _pickedArt;

  @override
  void initState() {
    super.initState();
    final t = widget.track;
    final m = widget.movie;
    _c = widget.isTrack
        ? {
            'title': TextEditingController(text: t!.title),
            'artist': TextEditingController(text: t.artist),
            'album': TextEditingController(text: t.album),
            'genre': TextEditingController(text: t.genre),
            'year': TextEditingController(text: t.year == 0 ? '' : '${t.year}'),
          }
        : {
            'title': TextEditingController(text: m!.title),
            'year': TextEditingController(text: m.year == 0 ? '' : '${m.year}'),
            'series': TextEditingController(text: m.series),
            'season':
                TextEditingController(text: m.season == 0 ? '' : '${m.season}'),
            'episode': TextEditingController(
                text: m.episode == 0 ? '' : '${m.episode}'),
            'overview': TextEditingController(text: m.overview),
          };
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _t(String k) => _c[k]!.text.trim();
  int? _i(String k) {
    final v = _t(k);
    return v.isEmpty ? null : int.tryParse(v);
  }

  Future<void> _pickArt() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp']),
    ]);
    if (f != null) setState(() => _pickedArt = File(f.path));
  }

  Future<void> _save() async {
    if (_t('title').isEmpty) {
      setState(() => _error = "Title can't be empty.");
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final api = ref.read(vaultClientProvider).admin;
    try {
      if (widget.isTrack) {
        await api.editTrack(
          widget.id,
          title: _t('title'),
          artist: _t('artist'),
          album: _t('album'),
          genre: _t('genre'),
          year: _i('year') ?? 0,
        );
        if (_pickedArt != null) {
          await api.setTrackArt(widget.id, await _pickedArt!.readAsBytes());
        }
        // Local refresh; other devices get it from the change feed.
        ref.invalidate(catalogTracksProvider);
      } else {
        await api.editMovie(
          widget.id,
          title: _t('title'),
          year: _i('year') ?? 0,
          series: _t('series'),
          season: _i('season') ?? 0,
          episode: _i('episode') ?? 0,
          overview: _t('overview'),
        );
        if (_pickedArt != null) {
          await api.setMovieArt(widget.id, await _pickedArt!.readAsBytes());
        }
        ref.invalidate(movieCatalogProvider);
        ref.invalidate(movieDetailProvider(widget.id));
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fields = widget.isTrack
        ? const [
            ('title', 'Title', false),
            ('artist', 'Artist', false),
            ('album', 'Album', false),
            ('genre', 'Genre', false),
            ('year', 'Year', true),
          ]
        : const [
            ('title', 'Title', false),
            ('year', 'Year', true),
            ('series', 'Series (episodes only)', false),
            ('season', 'Season', true),
            ('episode', 'Episode', true),
            ('overview', 'Overview', false),
          ];

    return AlertDialog(
      title: Text(widget.isTrack ? 'Edit track' : 'Edit movie'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (key, label, numeric) in fields) ...[
                TextField(
                  controller: _c[key],
                  keyboardType:
                      numeric ? TextInputType.number : TextInputType.text,
                  maxLines: key == 'overview' ? 3 : 1,
                  decoration: InputDecoration(
                    labelText: label,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              const Divider(height: 20),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _pickArt,
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: Text(widget.isTrack
                        ? 'Replace cover…'
                        : 'Replace poster…'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _pickedArt == null
                          ? 'Optional — leaves the current art alone.'
                          : _pickedArt!.path.split(Platform.pathSeparator).last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12.5)),
              ],
              const SizedBox(height: 8),
              Text(
                'Edits are stored on the server and survive rescans. Artwork '
                'is saved beside the file — the media itself is never rewritten.',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
