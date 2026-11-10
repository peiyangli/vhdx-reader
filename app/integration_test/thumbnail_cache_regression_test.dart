// One Windows process, including real decoder and fresh-cache reopen checks.
import 'thumbnails_test.dart' as plain;
import 'bitlocker_thumbnails_test.dart' as encrypted;

void main() {
  plain.main();
  encrypted.main();
}
