import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../capability/capability.dart';
import '../jobs/job.dart';
import '../models/file_node.dart';
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

  /// Register a picked local file as a pending-upload (localOnly) node.
  Future<String> addLocalFile(String? parentId, String name,
      {int? size, FileMediaKind mediaKind = FileMediaKind.none});

  Future<void> rename(String id, String newName);

  Future<void> setPinned(String id, bool pinned);

  /// Soft-delete → trash (never destroys).
  Future<void> trash(String id);
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
  final session = ref.watch(sessionProvider).asData?.value;
  final VaultClient client = session != null
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
