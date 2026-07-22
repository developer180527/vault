import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../capability/capability.dart';
import '../jobs/job.dart';
import '../models/file_node.dart';
import '../models/playlist.dart';
import '../models/server_movie.dart';
import '../models/server_photo.dart';
import '../models/server_track.dart';
import '../services/service_registry.dart';
import 'http_vault_client.dart';
import 'mock_vault_client.dart';

/// THE seam between the client app and a Vault server. Every feature talks to
/// the server exclusively through this interface — never raw HTTP, never its
/// own mock. Today the only implementation is [MockVaultClient]; when vaultd
/// exists, an HttpVaultClient implements the same contract and the entire app
/// goes real by swapping one provider.
///
/// TODO(backend): this interface *is* the API contract draft for vaultd —
/// keep it in lockstep with the server's OpenAPI spec once that exists.
abstract interface class VaultClient {
  /// The capability manifest for this device+profile: which services are
  /// visible and which actions are granted. Fail-closed on error.
  Future<CapabilityManifest> fetchManifest();

  /// The user's file namespace (list/create/rename/trash/pin).
  FileRepository get files;

  /// Background work: submit torrent/URL-download/upload jobs and observe
  /// their lifecycle. Execution is scheduled automatically (by the server —
  /// or the mock's in-process scheduler).
  VaultJobsApi get jobs;

  /// The SERVER's music library (list/search/stream — docs/MUSIC.md).
  /// Standalone mode plays local files instead and never calls this.
  MusicApi get music;

  /// Camera-roll backup: hash-check + upload originals, list what's stored.
  /// Standalone mode has no server to back up to and never calls this.
  PhotosApi get photos;

  /// The shared movie/show catalog (browse/stream — docs/MOVIES.md).
  MoviesApi get movies;

  /// Sync folders: push a local folder into the vault (browsable everywhere)
  /// and read its provenance. Standalone has no server and never calls this.
  SyncApi get sync;

  /// The caller's profile picture, or null when none is set (or standalone).
  Future<Uint8List?> myAvatar();

  /// Upload raw image bytes as the caller's profile picture (server-side
  /// sniffed: non-images are rejected).
  Future<void> setMyAvatar(Uint8List bytes);

  /// Release any resources (streams, timers, sockets).
  void dispose();
}

/// Read/mutate side of the file namespace. Backed later by the drift mirror
/// that the sync engine keeps current from the server journal; the UI always
/// reads through this — never the server directly.
abstract interface class FileRepository {
  /// Direct children of [parentId] (null = the My Files root), already sorted
  /// (folders first, then name).
  Future<List<FileNode>> children(String? parentId);

  /// A node by id, for breadcrumb/detail.
  Future<FileNode?> node(String id);

  /// The chain from the root down to [id], for the breadcrumb.
  Future<List<FileNode>> pathTo(String id);

  /// Create a folder under [parentId]. Returns its id.
  Future<String> createFolder(String? parentId, String name);

  /// Stream a picked local file's [bytes] ([length] bytes) into [parentId]
  /// (null = My Files root). Returns the created node id. The bytes actually
  /// travel to the server — a streamed body, so large files never load into
  /// memory.
  Future<String> uploadFile(
      String? parentId, String name, Stream<List<int>> bytes, int length,
      {FileMediaKind mediaKind = FileMediaKind.none});

  Future<void> rename(String id, String newName);

  /// Whether this backend can honor offline pinning. When false the UI hides
  /// the pin action entirely (never show a control that silently no-ops).
  bool get supportsPinning;

  Future<void> setPinned(String id, bool pinned);

  /// Soft-delete → trash (never destroys).
  Future<void> trash(String id);
}

/// Server music library: the index lives on the server; bytes stream with
/// Range support. Uris are fetched with [authHeaders] by the playback engine.
///
/// Two libraries share this seam: the caller's PERSONAL music zone
/// (tracks/search/streamUri) and the SHARED admin-curated catalog everyone
/// streams from (catalog*, playlists, listens — docs/MUSIC.md).
abstract interface class MusicApi {
  /// The whole personal library (the server rescans incrementally per call).
  Future<List<ServerTrack>> tracks();

  /// FTS prefix search over the personal library.
  Future<List<ServerTrack>> search(String query);

  Uri streamUri(String id);
  Uri artUri(String id);

  /// Resolves a server-relative signed stream path (`stream_url` on a track —
  /// path plus query) against this server's origin. Signed URLs carry their
  /// own auth, so playback outlives the 15-minute bearer.
  Uri resolveStreamUrl(String pathWithQuery);

  /// Mints a fresh signed stream URL for one track ([catalog] picks the shared
  /// endpoint). Used as a one-shot retry when a cached listing's signature has
  /// gone stale; null when unavailable (old server / not connected).
  Future<Uri?> freshStreamUrl(String id, {bool catalog = false});

  /// The shared catalog: full list when [query] is empty, FTS prefix search
  /// otherwise. Pure server-DB read — the admin curates and scans.
  Future<List<ServerTrack>> catalog({String query = ''});

  Uri catalogStreamUri(String id);
  Uri catalogArtUri(String id);

  /// The caller's playlists (catalog track UUIDs + owner UUID, server-side).
  Future<List<Playlist>> playlists();
  Future<Playlist> createPlaylist(String name);
  Future<void> deletePlaylist(String id);
  Future<List<ServerTrack>> playlistTracks(String id);
  Future<void> addToPlaylist(String playlistId, String trackId);
  Future<void> removeFromPlaylist(String playlistId, String trackId);

  /// Report one raw listen event — the food for future recommendations.
  /// Fire-and-forget: playback must never stall on telemetry.
  Future<void> reportListen(String trackId,
      {String source = '', int msPlayed = 0});

  /// The caller's "You" shelf: top catalog tracks by total play time. Empty
  /// until they've listened to something.
  Future<List<ServerTrack>> mostPlayed();

  /// The caller's liked songs over the shared catalog (newest-liked first).
  Future<List<ServerTrack>> favorites();

  /// Like / unlike a catalog track for the caller. Idempotent both ways.
  Future<void> addFavorite(String trackId);
  Future<void> removeFavorite(String trackId);

  /// Bearer header for stream/artwork requests (refreshed if expired).
  Future<Map<String, String>> authHeaders();
}

/// Camera-roll backup against vaultd's /v1/photos endpoints. The engine's
/// contract: ask which content hashes the server is missing, upload exactly
/// those (originals, streamed from disk), list what's stored for the status
/// surface.
abstract interface class PhotosApi {
  /// The subset of [hashes] the server does NOT have yet for this user.
  Future<List<String>> checkMissing(List<String> hashes);

  /// Upload one original from a local file path (streamed — videos never load
  /// into memory). [hash] is verified server-side; a corrupted transfer is
  /// rejected rather than stored. Idempotent: re-uploading returns the
  /// existing row. [thumb] is an optional client-generated JPEG preview —
  /// the phone decodes HEIC for free, the server never needs image codecs.
  Future<ServerPhoto> upload({
    required String path,
    required String name,
    required String hash,
    DateTime? takenAt,
    Uint8List? thumb,
  });

  /// One page of the backed-up listing, newest capture first, with totals.
  Future<PhotoBackupListing> list({int limit = 200, int offset = 0});

  /// Timeline/viewer URLs (fetched with [MusicApi.authHeaders]-style bearer
  /// via the content cache).
  Uri thumbUri(String id);
  Uri contentUri(String id);

  /// Rows still lacking a thumbnail, as (id, contentHash) pairs — the client
  /// maps hash → local asset through its ledger and backfills.
  Future<List<(String id, String hash)>> missingThumbs();

  /// Store a thumbnail for an already-backed-up original.
  Future<void> setThumb(String id, Uint8List jpeg);

  /// Bearer headers for thumb/content fetches from image widgets.
  Future<Map<String, String>> authHeaders();
}

/// The shared movie/show catalog (docs/MOVIES.md). Mirrors [MusicApi]: list/
/// search + signed stream URLs, plus movie-specific multi-track streaming
/// (audio selection, WebVTT subtitles) and server-side resume.
abstract interface class MoviesApi {
  /// The whole catalog (or FTS search results).
  Future<List<ServerMovie>> list({String query = ''});

  /// Titles the caller started but hasn't finished — the resume shelf.
  Future<List<ServerMovie>> continueWatching();

  /// One title with the caller's resume position + full stream list.
  Future<ServerMovie> movie(String id);

  /// Report playback progress (resume point + finished detection). Fire-and-
  /// forget: playback never stalls on telemetry.
  Future<void> reportWatch(String id, {required int positionMs, required int durationMs});

  /// Stream URL for a title. [audio] > 0 selects a non-default track (server
  /// remuxes); [startSec] server-seeks (a remuxed pipe can't Range-seek).
  Uri streamUri(String id,
      {int audio = 0, int startSec = 0, bool remux = false, bool transcode = false});

  /// Resolve a server-provided signed stream path (bearer-free playback).
  Uri resolveStreamUrl(String pathWithQuery);

  Uri artUri(String id);

  /// A subtitle track as WebVTT. [track] is `e<N>` (embedded) or `x<N>`
  /// (sidecar), matching [ServerMovie.subs] ordering.
  Uri subUri(String id, String track);

  /// Fetch a subtitle track's WebVTT text (authed) for the caption overlay.
  Future<String> subtitleVtt(String id, String track);

  /// Bearer headers for art/stream fetches.
  Future<Map<String, String>> authHeaders();
}

/// Provenance of a folder a device pushed into the vault.
class SyncedFolderInfo {
  const SyncedFolderInfo({
    required this.id,
    required this.name,
    required this.relPath,
    this.originDevice = '',
    this.originPlatform = '',
    this.createdAt = 0,
    this.lastSyncAt = 0,
    this.fileCount = 0,
    this.totalBytes = 0,
  });

  final String id;
  final String name;
  final String relPath;
  final String originDevice;
  final String originPlatform;
  final int createdAt;
  final int lastSyncAt;
  final int fileCount;
  final int totalBytes;

  factory SyncedFolderInfo.fromJson(Map<String, Object?> j) => SyncedFolderInfo(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    relPath: (j['rel_path'] as String?) ?? '',
    originDevice: (j['origin_device'] as String?) ?? '',
    originPlatform: (j['origin_platform'] as String?) ?? '',
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    lastSyncAt: (j['last_sync_at'] as num?)?.toInt() ?? 0,
    fileCount: (j['file_count'] as num?)?.toInt() ?? 0,
    totalBytes: (j['total_bytes'] as num?)?.toInt() ?? 0,
  );
}

/// Sync a device folder into the vault so any device can reach it, plus the
/// provenance the app surfaces. Files themselves land through the Files
/// service's upload path (a synced folder IS a Files-zone folder).
abstract interface class SyncApi {
  /// The caller's synced folders with provenance.
  Future<List<SyncedFolderInfo>> list();

  /// Create a synced folder; returns its record and the Files node id to
  /// upload into.
  Future<(SyncedFolderInfo info, String nodeId)> create({
    required String name,
    required String originDevice,
    required String originPlatform,
  });

  /// Stream one file's bytes into a folder node (reuses the Files upload path).
  /// Returns the created file node id.
  Future<String> uploadInto(String parentNodeId, String name, Stream<List<int>> bytes, int length);

  /// Create a subfolder under a folder node; returns its node id.
  Future<String> makeSubfolder(String parentNodeId, String name);

  /// Record the tally after a push completes (drives the info panel).
  Future<void> touch(String id, {required int fileCount, required int totalBytes});

  /// Drop the provenance record (files stay in the Files zone).
  Future<void> delete(String id);
}

/// The jobs pipeline. Submitting hands work to the scheduler; [watch] streams
/// list snapshots as jobs advance so any number of views stay live.
abstract interface class VaultJobsApi {
  Future<VaultJob> submit(JobRequest request);

  /// Stop a queued/running job. Finished jobs are unaffected.
  Future<void> cancel(String id);

  /// Re-queue a failed/canceled job; the scheduler picks it up automatically.
  Future<void> retry(String id);

  /// Drop completed/failed/canceled jobs from the list.
  Future<void> clearFinished();

  /// Emits the current job list immediately on listen, then on every change,
  /// newest first.
  Stream<List<VaultJob>> watch();
}

/// The active client. THE mock→real switch: a connected device session means
/// the real server (HttpVaultClient); no session means the in-process mock —
/// so the app is fully usable before a server is configured, and tests never
/// touch the network.
final vaultClientProvider = Provider<VaultClient>((ref) {
  // select: rebuild only when CONNECTEDNESS flips (login/logout) — not on
  // every session mutation. Token refreshes and noteUsername update the
  // session object mid-request; rebuilding here disposed the client that
  // was mid-fetch, killing it with "Ref used after dispose". The client
  // always reads the CURRENT session per-call anyway.
  final connected = ref.watch(
    sessionProvider.select((s) => s.asData?.value != null),
  );
  final VaultClient client = connected
      ? HttpVaultClient(ref)
      : MockVaultClient(
          // Deferred: only fetchManifest needs the registry, and reading it
          // lazily keeps bare test containers (which never fetch) working.
          serviceIds: () =>
              ref.read(serviceRegistryProvider).map((s) => s.id).toList(),
        );
  ref.onDispose(client.dispose);
  return client;
});
