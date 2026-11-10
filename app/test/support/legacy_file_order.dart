// Frozen pre-PERF-02 reference for equivalence tests and benchmarks.
import 'package:vhdx_reader/file_order.dart' show FileSort;
import 'package:vhdx_reader/file_types.dart';

List<Map<String, dynamic>> legacySortedFiles(
  List<Map<String, dynamic>> source,
  FileSort sort,
  bool descending,
) => [...source]
  ..sort((a, b) {
    final folders =
        (b['directory'] == true ? 1 : 0) - (a['directory'] == true ? 1 : 0);
    if (folders != 0) return folders;
    var result = 0;
    if (sort == FileSort.modified) {
      final left = a['modified_unix_ms'] as int?;
      final right = b['modified_unix_ms'] as int?;
      // Unknown dates stay at the end in both directions.
      if (left == null && right != null) return 1;
      if (left != null && right == null) return -1;
      if (left != null && right != null) result = left.compareTo(right);
    }
    if (a['directory'] != true) {
      if (sort == FileSort.size) {
        result = (a['size'] as int).compareTo(b['size'] as int);
      } else if (sort == FileSort.type) {
        result = friendlyTypeOrder(
          a['name'] as String,
        ).compareTo(friendlyTypeOrder(b['name'] as String));
      }
    }
    if (result == 0) {
      result = legacyCompareFileNames(a['name'] as String, b['name'] as String);
    }
    return descending ? -result : result;
  });

int legacyCompareFileNames(String a, String b) {
  final pieces = RegExp(r'\d+|\D+');
  final left = pieces.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = pieces.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = left[i];
    final y = right[i];
    final nx = BigInt.tryParse(x);
    final ny = BigInt.tryParse(y);
    final order = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (order != 0) return order;
  }
  final length = left.length.compareTo(right.length);
  return length != 0 ? length : a.compareTo(b);
}
