import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

// Unit widgets do not use the real application cache directory. Disk-cache
// tests inject their own directory; native integration tests use the platform.
class _UnitPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationCachePath() async =>
      throw MissingPluginException('Inject a cache directory in unit tests');
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _UnitPaths();
  await testMain();
}
