import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/client/mock_vault_client.dart';
import 'package:vault/core/jobs/job.dart';

/// Fast scheduler for tests: 2ms ticks finish a job in ~20-40ms real time.
MockVaultClient _client({int maxConcurrent = 2}) => MockVaultClient(
      serviceIds: () => const [],
      jobTick: const Duration(milliseconds: 2),
      maxConcurrentJobs: maxConcurrent,
    );

/// Polls the job list until [predicate] holds (or times out).
Future<List<VaultJob>> _until(
  MockVaultClient client,
  bool Function(List<VaultJob>) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final jobs = await client.jobs.watch().first;
    if (predicate(jobs)) return jobs;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for job state');
}

void main() {
  test('submitted job is scheduled automatically and completes', () async {
    final client = _client();
    addTearDown(client.dispose);

    final job = await client.jobs.submit(const JobRequest(
        kind: JobKind.download, source: 'https://example.com/video'));
    expect(job.state, JobState.queued);

    final done = await _until(
        client, (jobs) => jobs.single.state == JobState.completed);
    expect(done.single.progress, 1.0);
  });

  test('scheduler caps concurrency and drains the queue', () async {
    final client = _client(maxConcurrent: 2);
    addTearDown(client.dispose);

    for (var i = 0; i < 3; i++) {
      await client.jobs.submit(
          JobRequest(kind: JobKind.download, source: 'https://x.test/$i'));
    }

    // Immediately after submission: 2 running, 1 waiting.
    final jobs = await client.jobs.watch().first;
    expect(jobs.where((j) => j.state == JobState.running).length, 2);
    expect(jobs.where((j) => j.state == JobState.queued).length, 1);

    // The queued one is started automatically as slots free; all finish.
    await _until(client,
        (jobs) => jobs.every((j) => j.state == JobState.completed));
  });

  test('a failing job reports failed and can be retried', () async {
    final client = _client();
    addTearDown(client.dispose);

    final job = await client.jobs.submit(const JobRequest(
        kind: JobKind.torrent, source: 'magnet:?xt=x&dn=will-fail'));

    await _until(client, (jobs) => jobs.single.state == JobState.failed);

    await client.jobs.retry(job.id);
    final retried = await client.jobs.watch().first;
    expect(retried.single.state,
        anyOf(JobState.queued, JobState.running)); // re-scheduled
    expect(retried.single.progress, lessThan(1));

    // Wait for it to finish again so no timers outlive the test.
    await _until(client, (jobs) => jobs.single.state.isFinished);
  });

  test('cancel stops a job; clearFinished removes finished only', () async {
    final client = _client();
    addTearDown(client.dispose);

    final a = await client.jobs.submit(const JobRequest(
        kind: JobKind.download, source: 'https://x.test/a'));
    await client.jobs.cancel(a.id);

    var jobs = await client.jobs.watch().first;
    expect(jobs.single.state, JobState.canceled);

    final b = await client.jobs.submit(const JobRequest(
        kind: JobKind.download, source: 'https://x.test/b'));
    await client.jobs.clearFinished();

    jobs = await client.jobs.watch().first;
    // The canceled job is gone; the active one survives.
    expect(jobs.map((j) => j.id), [b.id]);
    await _until(client, (jobs) => jobs.single.state.isFinished);
  });

  test('titles derive from magnet display names and URL tails', () async {
    final client = _client();
    addTearDown(client.dispose);

    final magnet = await client.jobs.submit(const JobRequest(
        kind: JobKind.torrent, source: 'magnet:?xt=urn:btih:abc&dn=My+Movie'));
    final url = await client.jobs.submit(const JobRequest(
        kind: JobKind.download, source: 'https://y.test/clips/episode-1.mp4'));

    expect(magnet.title, 'My Movie');
    expect(url.title, 'episode-1.mp4');
    await _until(client, (jobs) => jobs.every((j) => j.state.isFinished));
  });
}
