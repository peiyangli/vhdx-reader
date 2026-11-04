import 'dart:io';

final fixtureOverrides = <String, String>{};

/// Desktop tests inherit process variables; iOS tests receive explicit Dart defines.
String? fixtureSetting(String name) {
  const defines = {
    'VHDX_SAMPLE_DIR': String.fromEnvironment('VHDX_SAMPLE_DIR'),
    'VHDX_PDF_FIXTURE': String.fromEnvironment('VHDX_PDF_FIXTURE'),
    'VHDX_MEDIA_FIXTURE': String.fromEnvironment('VHDX_MEDIA_FIXTURE'),
    'VHDX_SCREENSHOT': String.fromEnvironment('VHDX_SCREENSHOT'),
    'VHDX_PDF_SCREENSHOT': String.fromEnvironment('VHDX_PDF_SCREENSHOT'),
    'VHDX_MEDIA_SCREENSHOT': String.fromEnvironment('VHDX_MEDIA_SCREENSHOT'),
  };
  final value =
      fixtureOverrides[name] ?? Platform.environment[name] ?? defines[name];
  return value == null || value.isEmpty ? null : value;
}
