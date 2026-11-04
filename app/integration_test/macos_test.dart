import 'vault_test.dart' as vault;
import 'native_test.dart' as native;
import 'pdf_test.dart' as pdf;
import 'media_test.dart' as media;

// The Mac runner is sandboxed. scripts/test-macos.sh places private fixtures in
// its container, keeping the production sandbox and packaged native libraries.
void main() {
  vault.main();
  native.main();
  pdf.main();
  media.main();
}
