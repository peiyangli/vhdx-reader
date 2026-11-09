// One Windows host launch verifies the release defaults and both diagnostic paths.
import 'media_transport_regression_test.dart' as playback;
import 'thumbnail_limits_test.dart' as thumbnails;
import 'cache_settings_test.dart' as cache;
import 'disk_cache_test.dart' as disk;

void main() {
  playback.main();
  thumbnails.main();
  cache.main();
  disk.main();
}
