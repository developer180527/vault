import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/features/photos/data/backup_engine.dart';
import 'package:vault/features/photos/data/backup_status.dart';

/// The bug these guard against, observed on a real device: after sideloading a
/// fresh build, iOS wiped the app container and with it the backup ledger. The
/// next pass re-hashed all 792 photos, confirmed against the server that every
/// one was already stored, and uploaded NOTHING — but the UI reported the whole
/// thing as "Backing up…", which reads as a full re-upload of the library.
///
/// The server was never at risk (792 rows, 792 distinct hashes, zero uploads in
/// the request log). Only the wording was wrong. So these tests are about
/// wording, and the invariant is: never imply bytes are moving when they aren't.
void main() {
  BackupState verifying({int done = 300, int found = 792, int uploaded = 0}) =>
      BackupState(
          phase: BackupPhase.verifying,
          done: done,
          found: found,
          uploaded: uploaded);

  group('a pass that uploads nothing never claims otherwise', () {
    test('verifying does not use upload language', () {
      final s = verifying();
      expect(backupStatusTitle(s), isNot(contains('Backing up')));
      expect(backupStatusTitle(s), contains('Checking'));
      // The reassurance that was missing: it is not queuing anything.
      expect(backupProgressDetail(s), contains('nothing to upload'));
      expect(backupProgressDetail(s), contains('300 of 792'));
      expect(backupTooltip(s), isNot(contains('Backing up')));
    });

    test('the icon agrees with the words — no upload arrow while verifying', () {
      // The glyph is read faster than the text, so a cloud-with-up-arrow here
      // would undo the whole fix.
      expect(backupStatusIcon(verifying()), isNot(Icons.cloud_upload_outlined));
      expect(backupStatusIcon(verifying()), Icons.cloud_sync_outlined);
    });

    test('finishing with zero uploads says so explicitly', () {
      const s = BackupState(
          phase: BackupPhase.done, done: 792, found: 792, uploaded: 0);
      expect(backupStatusTitle(s), 'Everything already backed up');
      expect(backupProgressDetail(s), contains('already on your server'));
    });
  });

  group('real uploads are still reported as uploads', () {
    test('uploading phase keeps upload language and the current filename', () {
      const s = BackupState(
          phase: BackupPhase.uploading,
          done: 780,
          found: 792,
          uploaded: 12,
          current: 'IMG_0042.HEIC');
      expect(backupStatusTitle(s), 'Backing up…');
      expect(backupProgressDetail(s), contains('IMG_0042.HEIC'));
      expect(backupStatusIcon(s), Icons.cloud_upload_outlined);
    });

    test('finishing with uploads reports the count, singular and plural', () {
      const one = BackupState(
          phase: BackupPhase.done, done: 792, found: 792, uploaded: 1);
      expect(backupStatusTitle(one), 'Backed up');
      expect(backupProgressDetail(one), 'Uploaded 1 new item');

      const many = BackupState(
          phase: BackupPhase.done, done: 792, found: 792, uploaded: 67);
      expect(backupProgressDetail(many), 'Uploaded 67 new items');
    });
  });

  test('verifying counts as running, so progress stays on screen', () {
    // If this regressed the spinner would vanish during the longest phase of
    // the run and the pass would look hung.
    expect(backupIsRunning(verifying()), isTrue);
    expect(backupIsRunning(const BackupState(phase: BackupPhase.scanning)),
        isTrue);
    expect(backupIsRunning(const BackupState(phase: BackupPhase.done)), isFalse);
    expect(backupIsRunning(const BackupState()), isFalse);
  });
}
