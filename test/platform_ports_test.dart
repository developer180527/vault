import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/platform/background_runner.dart';
import 'package:vault/core/platform/file_system_access.dart';
import 'package:vault/core/platform/media_codec.dart';
import 'package:vault/core/platform/notifications.dart';

void main() {
  group('planPlayback (shared media decision)', () {
    const support = MediaSupport(
      video: {VideoCodec.h264},
      audio: {AudioCodec.aac},
      hardwareDecode: false,
    );

    test('direct-plays a fully supported track', () {
      final plan = planPlayback(
        const MediaTrack(
            container: 'mp4', video: VideoCodec.h264, audio: AudioCodec.aac),
        support,
      );
      expect(plan, isA<DirectPlay>());
    });

    test('transcodes when the video codec is unsupported', () {
      final plan = planPlayback(
        const MediaTrack(
            container: 'mkv', video: VideoCodec.av1, audio: AudioCodec.aac),
        support,
      );
      expect(plan, isA<NeedsTranscode>());
      expect((plan as NeedsTranscode).targetProfile, isNotEmpty);
    });
  });

  test('stub ports report their conservative capability descriptors', () async {
    expect(StubBackgroundRunner().model, BackgroundModel.foregroundOnly);
    expect(const StubFileSystemAccess().storage, StorageModel.pickerOnly);
    expect(const StubFileSystemAccess().canWatchDirectories, isFalse);
    expect(const StubNotifications().supportsPush, isFalse);

    final support = await const StubMediaCodec().probe();
    expect(support.video, contains(VideoCodec.h264));
    expect(support.isEmpty, isFalse);
  });

  test('stub background runner echoes a job lifecycle', () async {
    final runner = StubBackgroundRunner();
    addTearDown(runner.dispose);

    final events = <BackgroundJobEvent>[];
    final sub = runner.events().listen(events.add);

    await runner.enqueue(
        const BackgroundJobSpec(id: 'j1', kind: JobKind.upload));
    await runner.cancel('j1');
    await Future<void>.delayed(Duration.zero);

    expect(events.map((e) => e.status),
        containsAllInOrder([JobStatus.queued, JobStatus.cancelled]));
    await sub.cancel();
  });
}
