import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/models/server_movie.dart';
import 'package:vault/core/platform/media_codec.dart';
import 'package:vault/features/movies/data/movie_playback.dart';

/// A capable modern device: H.264/HEVC video, AAC audio.
const _device = MediaSupport(
  video: {VideoCodec.h264, VideoCodec.hevc},
  audio: {AudioCodec.aac},
  hardwareDecode: true,
);

ServerMovie _movie({
  required String container,
  String vcodec = 'h264',
  List<MovieAudio> audio = const [MovieAudio(index: 0, codec: 'aac')],
}) =>
    ServerMovie(
      id: 'm1',
      title: 'T',
      kind: 'movie',
      container: container,
      vcodec: vcodec,
      audio: audio,
    );

void main() {
  // The whole reason the libmpv engine exists: AVPlayer cannot open Matroska,
  // and the server-remux workaround streams from an ffmpeg pipe that can't
  // answer Range requests — AVPlayer drops the connection within ~100ms and
  // the user sees "Playback failed". Anything the native engine can't direct-
  // play must therefore be routed to libmpv, not to a remux.
  test('MKV goes to libmpv even when the codecs are natively decodable', () {
    final mkv = _movie(container: 'matroska,webm');
    expect(movieStreamMode(mkv, _device), MovieStreamMode.remux);
    expect(videoEngineFor(mkv, _device), VideoEngine.libmpv);
  });

  test('a directly playable MP4 keeps the native engine', () {
    // Native keeps hardware decode, system PiP and lock-screen controls, so it
    // stays the default wherever it actually works.
    final mp4 = _movie(container: 'mov,mp4,m4a,3gp,3g2,mj2');
    expect(movieStreamMode(mp4, _device), MovieStreamMode.direct);
    expect(videoEngineFor(mp4, _device), VideoEngine.native);
  });

  test('an undecodable codec goes to libmpv rather than a CPU transcode', () {
    // AC-3 in an MP4: the container is fine but the device can't decode the
    // audio. Previously this meant a full server re-encode; libmpv just plays
    // it, so the server never burns CPU.
    final ac3 = _movie(
      container: 'mov,mp4,m4a',
      audio: const [MovieAudio(index: 0, codec: 'ac3', channels: 6)],
    );
    expect(movieStreamMode(ac3, _device), MovieStreamMode.transcode);
    expect(videoEngineFor(ac3, _device), VideoEngine.libmpv);
  });

  test('a dual-audio MKV routes to libmpv, where switching is in-player', () {
    final dual = _movie(
      container: 'matroska,webm',
      audio: const [
        MovieAudio(index: 0, lang: 'jpn', title: 'Japanese (Original)',
            codec: 'aac', isDefault: true),
        MovieAudio(index: 1, lang: 'eng', title: 'English (Dub)', codec: 'aac'),
      ],
    );
    expect(videoEngineFor(dual, _device), VideoEngine.libmpv);
    // The picker's labels come from the server descriptor either way, so the
    // two engines present identical menus.
    expect(dual.audio.map((a) => a.label).toList(),
        ['Japanese (Original)', 'English (Dub)']);
  });
}
