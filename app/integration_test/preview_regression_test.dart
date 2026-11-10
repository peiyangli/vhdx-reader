// Run in one Windows process: the desktop application has a single-instance guard.
import 'preview_binary_test.dart' as binary;
import 'pdf_test.dart' as pdf;
import 'thumbnails_test.dart' as thumbnails;

void main() {
  binary.main();
  pdf.main();
  thumbnails.main();
}
