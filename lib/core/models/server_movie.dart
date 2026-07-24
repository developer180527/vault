import 'package:flutter/foundation.dart';

/// One selectable audio track (Japanese original, English dub, …).
@immutable
class MovieAudio {
  const MovieAudio({
    required this.index,
    this.lang = '',
    this.title = '',
    this.codec = '',
    this.channels = 0,
    this.isDefault = false,
  });

  final int index;
  final String lang;
  final String title;
  final String codec;
  final int channels;
  final bool isDefault;

  factory MovieAudio.fromJson(Map<String, Object?> j) => MovieAudio(
    index: (j['index'] as num?)?.toInt() ?? 0,
    lang: (j['lang'] as String?) ?? '',
    title: (j['title'] as String?) ?? '',
    codec: (j['codec'] as String?) ?? '',
    channels: (j['channels'] as num?)?.toInt() ?? 0,
    isDefault: (j['default'] as bool?) ?? false,
  );

  /// Human label: "English Dub", "日本語 (Original)", or a language/codec
  /// fallback so a picker row is never blank.
  String get label {
    if (title.isNotEmpty) return title;
    final l = _langName(lang);
    final ch = channels == 6
        ? ' 5.1'
        : channels == 8
        ? ' 7.1'
        : '';
    return l.isEmpty ? 'Track ${index + 1}$ch' : '$l$ch';
  }
}

/// One subtitle track. [text] tracks convert to WebVTT; image subs don't
/// (surfaced but not selectable yet). [external] marks a sidecar file.
@immutable
class MovieSub {
  const MovieSub({
    required this.index,
    this.lang = '',
    this.title = '',
    this.codec = '',
    this.forced = false,
    this.text = false,
    this.external = '',
  });

  final int index;
  final String lang;
  final String title;
  final String codec;
  final bool forced;
  final bool text;
  final String external;

  factory MovieSub.fromJson(Map<String, Object?> j) => MovieSub(
    index: (j['index'] as num?)?.toInt() ?? 0,
    lang: (j['lang'] as String?) ?? '',
    title: (j['title'] as String?) ?? '',
    codec: (j['codec'] as String?) ?? '',
    forced: (j['forced'] as bool?) ?? false,
    text: (j['text'] as bool?) ?? false,
    external: (j['external'] as String?) ?? '',
  );

  bool get isExternal => external.isNotEmpty;

  String get label {
    final l = _langName(lang);
    final base = title.isNotEmpty
        ? title
        : (l.isEmpty ? 'Track ${index + 1}' : l);
    return forced ? '$base (forced)' : base;
  }
}

/// One title in the shared movie catalog — the client twin of vaultd's
/// store.CatalogMovie JSON.
@immutable
class ServerMovie {
  const ServerMovie({
    required this.id,
    required this.title,
    this.kind = 'movie',
    this.year = 0,
    this.series = '',
    this.season = 0,
    this.episode = 0,
    this.overview = '',
    this.durationMs = 0,
    this.vcodec = '',
    this.container = '',
    this.width = 0,
    this.height = 0,
    this.hasArt = false,
    this.artVersion = 0,
    this.resumeMs = 0,
    this.audio = const [],
    this.subs = const [],
    this.streamUrl,
  });

  final String id;
  final String title;
  final String kind; // movie | episode
  final int year;
  final String series;
  final int season;
  final int episode;
  final String overview;
  final int durationMs;
  final String vcodec;
  final String container;
  final int width;
  final int height;
  final bool hasArt;

  /// Poster cache-bust stamp from the server (0 = old server / none).
  final int artVersion;

  final int resumeMs;
  final List<MovieAudio> audio;
  final List<MovieSub> subs;
  final String? streamUrl;

  bool get isEpisode => kind == 'episode';

  /// Fraction watched (0..1), for the resume progress bar. 0 when unknown.
  double get progress =>
      durationMs > 0 && resumeMs > 0 ? (resumeMs / durationMs).clamp(0, 1) : 0;

  String get subtitle {
    if (isEpisode) {
      final tag = season > 0 ? 'S${season}E$episode · ' : '';
      return '$tag$series';
    }
    return year > 0 ? '$year' : '';
  }

  factory ServerMovie.fromJson(Map<String, Object?> j) {
    final streams = (j['streams'] as Map<String, Object?>?) ?? const {};
    return ServerMovie(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '',
      kind: (j['kind'] as String?) ?? 'movie',
      year: (j['year'] as num?)?.toInt() ?? 0,
      series: (j['series'] as String?) ?? '',
      season: (j['season'] as num?)?.toInt() ?? 0,
      episode: (j['episode'] as num?)?.toInt() ?? 0,
      overview: (j['overview'] as String?) ?? '',
      durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
      vcodec: (j['vcodec'] as String?) ?? '',
      container: (j['container'] as String?) ?? '',
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      hasArt: (j['has_art'] as bool?) ?? false,
      artVersion: (j['art_version'] as num?)?.toInt() ?? 0,
      resumeMs: (j['resume_ms'] as num?)?.toInt() ?? 0,
      audio: [
        for (final a in (streams['audio'] as List?) ?? const [])
          MovieAudio.fromJson(a as Map<String, Object?>),
      ],
      subs: [
        for (final s in (streams['subs'] as List?) ?? const [])
          MovieSub.fromJson(s as Map<String, Object?>),
      ],
      streamUrl: j['stream_url'] as String?,
    );
  }

  /// Wire-identical round-trip for snapshot caching.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'kind': kind,
    'year': year,
    'series': series,
    'season': season,
    'episode': episode,
    'overview': overview,
    'duration_ms': durationMs,
    'vcodec': vcodec,
    'container': container,
    'width': width,
    'height': height,
    'has_art': hasArt,
    if (artVersion != 0) 'art_version': artVersion,
    if (resumeMs > 0) 'resume_ms': resumeMs,
    'streams': {
      'audio': [
        for (final a in audio)
          {
            'index': a.index,
            'lang': a.lang,
            'title': a.title,
            'codec': a.codec,
            'channels': a.channels,
            'default': a.isDefault,
          },
      ],
      'subs': [
        for (final s in subs)
          {
            'index': s.index,
            'lang': s.lang,
            'title': s.title,
            'codec': s.codec,
            'forced': s.forced,
            'text': s.text,
            'external': s.external,
          },
      ],
    },
    if (streamUrl != null) 'stream_url': streamUrl,
  };
}

/// Minimal ISO-639 → display name for the tracks users actually have. Unknown
/// codes pass through uppercased so nothing renders blank.
String _langName(String code) {
  const names = {
    'eng': 'English', 'en': 'English',
    'jpn': '日本語', 'ja': '日本語',
    'hin': 'हिन्दी', 'hi': 'हिन्दी',
    'tam': 'தமிழ்', 'ta': 'தமிழ்',
    'tel': 'తెలుగు', 'te': 'తెలుగు',
    'kor': '한국어', 'ko': '한국어',
    'fra': 'Français', 'fre': 'Français', 'fr': 'Français',
    'spa': 'Español', 'es': 'Español',
    'ger': 'Deutsch', 'deu': 'Deutsch', 'de': 'Deutsch',
    'ita': 'Italiano', 'it': 'Italiano',
    'por': 'Português', 'pt': 'Português',
    'rus': 'Русский', 'ru': 'Русский',
    'zho': '中文', 'chi': '中文', 'zh': '中文',
    'ara': 'العربية', 'ar': 'العربية',
  };
  if (code.isEmpty) return '';
  return names[code.toLowerCase()] ?? code.toUpperCase();
}
