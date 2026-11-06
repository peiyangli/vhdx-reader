import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/window_chrome.dart';

void main() {
  test('desktop focus/minimize never replaces explicit tray visibility', () {
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final state in [null, ...AppLifecycleState.values]) {
        expect(readerIsForeground(platform, state), true);
      }
    }
  });
  test('mobile continues to suspend while inactive or backgrounded', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final state in AppLifecycleState.values) {
        expect(
          readerIsForeground(platform, state),
          state == AppLifecycleState.resumed,
        );
      }
    }
  });
}
