// One entrypoint avoids relaunching the Windows single-instance host between
// cases. Run with --dart-define=VHDX_MEDIA_TRANSPORT=native for callback coverage.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'test_configuration.dart';
import 'media_test.dart' as media;
import 'bitlocker_playback_test.dart' as bitlocker;
import 'media_failure_test.dart' as failure;

void main() {
  media.main();
  bitlocker.main();
  failure.main();
  testWidgets('cancelled preview still revokes its stream on dispose', (
    tester,
  ) async {
    final backend = await NativeBackend.start();
    try {
      await backend.request({
        'op': 'open',
        'path': fixtureSetting('VHDX_MEDIA_FIXTURE')!,
      });
      await backend.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
      final source = await failure.openPreview(tester, backend, '/sample.mp4');
      await media.waitFor(tester, () => source.position.inMilliseconds > 300);
      backend.cancel();
      source.dispose();
      await source.closed;
      backend.beginOperation();
      await expectLater(source.statistics(), throwsA(isA<ReaderFailure>()));
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await backend.dispose();
    }
  });
}
