import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'platform_storage.dart';

/// Use logical, safe dimensions rather than device names or orientation alone.
class ScreenLayout {
  ScreenLayout(BuildContext context) {
    final media = MediaQuery.of(context);
    width = media.size.width - media.padding.horizontal;
    height = media.size.height - media.padding.vertical;
    textScale = media.textScaler.scale(14) / 14;
  }
  late final double width;
  late final double height;
  late final double textScale;
  bool get compact => height < 500 && width > height;
  double get toolbarHeight => compact && textScale < 1.4 ? 48 : 60;
}

const readerSystemStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarContrastEnforced: false,
);

enum ScreenDirection {
  automatic('自动（跟随系统）'),
  portrait('固定竖屏'),
  landscape('固定横屏');

  const ScreenDirection(this.label);
  final String label;
  static Future<ScreenDirection> load() async {
    final value = await PlatformStorage.channel.invokeMethod<String>(
      'screenDirection',
    );
    return values.firstWhere((v) => v.name == value, orElse: () => automatic);
  }

  Future<void> apply() async {
    if (!Platform.isIOS) return;
    await SystemChrome.setPreferredOrientations(switch (this) {
      ScreenDirection.automatic => <DeviceOrientation>[],
      ScreenDirection.portrait => [DeviceOrientation.portraitUp],
      ScreenDirection.landscape => [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    });
  }

  Future<void> save() async {
    await PlatformStorage.channel.invokeMethod('setScreenDirection', {
      'value': name,
    });
    await apply();
  }
}

class ShakeRotation {
  static Future<Map<String, dynamic>> load() async => Map<String, dynamic>.from(
    await PlatformStorage.channel.invokeMapMethod<String, dynamic>(
          'shakeRotation',
        ) ??
        {},
  );
  static Future<void> save(bool value) => PlatformStorage.channel.invokeMethod(
    'setShakeRotation',
    {'value': value},
  );
}
