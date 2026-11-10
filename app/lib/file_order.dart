import 'file_types.dart';

enum FileSort { name, size, modified, type }

class _NamePart {
  _NamePart(this.text)
    : number = text.codeUnitAt(0) >= 48 && text.codeUnitAt(0) <= 57
          ? text.replaceFirst(_leadingZeros, '')
          : null;
  static final _leadingZeros = RegExp(r'^0+(?=\d)');
  final String text;
  final String? number;
}

class _NameKey {
  _NameKey(this.original)
    : parts = _pieces
          .allMatches(original.toLowerCase())
          .map((match) => _NamePart(match[0]!))
          .toList(growable: false);
  static final _pieces = RegExp(r'\d+|\D+');
  final String original;
  final List<_NamePart> parts;

  int compareTo(_NameKey other) {
    for (var i = 0; i < parts.length && i < other.parts.length; i++) {
      final a = parts[i];
      final b = other.parts[i];
      final int result;
      if (a.number != null && b.number != null) {
        final length = a.number!.length.compareTo(b.number!.length);
        result = length != 0 ? length : a.number!.compareTo(b.number!);
      } else {
        result = a.text.compareTo(b.text);
      }
      if (result != 0) return result;
    }
    final length = parts.length.compareTo(other.parts.length);
    return length != 0 ? length : original.compareTo(other.original);
  }
}

int compareFileNames(String a, String b) => _NameKey(a).compareTo(_NameKey(b));

class _EntryKey {
  _EntryKey(this.value, this.sequence)
    : name = _NameKey(value['name'] as String),
      folder = value['directory'] == true,
      size = value['size'] as int? ?? 0,
      modified = value['modified_unix_ms'] as int?,
      type = friendlyTypeOrder(value['name'] as String);
  final Map<String, dynamic> value;
  final int sequence;
  final _NameKey name;
  final bool folder;
  final int size;
  final int? modified;
  final int type;
}

/// Immutable view shared by list/grid rendering and video navigation.
class FileOrderSnapshot {
  FileOrderSnapshot._(List<_EntryKey> keys)
    : entries = List.unmodifiable(keys.map((key) => key.value)),
      _videos = List.unmodifiable(
        keys
            .where((key) => !key.folder && key.type == 1)
            .map((key) => key.value),
      );
  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> _videos;
  Map<String, int>? _positions;
  Map<String, int>? _videoPositions;

  int? indexOf(String name) {
    _positions ??= {
      for (var i = entries.length - 1; i >= 0; i--)
        entries[i]['name'] as String: i,
    };
    return _positions![name];
  }

  Map<String, dynamic>? adjacentVideo(String? current, int step) {
    _videoPositions ??= {
      for (var i = _videos.length - 1; i >= 0; i--)
        _videos[i]['name'] as String: i,
    };
    final index = _videoPositions![current];
    if (index == null) return null;
    final next = index + step;
    return next < 0 || next >= _videos.length ? null : _videos[next];
  }
}

/// Owns only the current directory. Prepare each entry's keys once, sort new
/// batches, and merge them into the published order. Snapshot reads are O(1)
/// when neither the directory nor the ordering changed.
class DirectoryOrder {
  final _all = <_EntryKey>[];
  List<_EntryKey> _sorted = [];
  FileSort? _sort;
  bool? _descending;
  FileOrderSnapshot? _snapshot;
  int get length => _all.length;

  /// Entry metadata is an immutable snapshot for the lifetime of this order.
  void add(Iterable<Map<String, dynamic>> entries) {
    for (final entry in entries) {
      _all.add(_EntryKey(entry, _all.length));
    }
  }

  FileOrderSnapshot snapshot(FileSort sort, bool descending) {
    if (_sort == sort &&
        _descending == descending &&
        _sorted.length == _all.length) {
      return _snapshot!;
    }
    int compare(_EntryKey a, _EntryKey b) {
      if (a.folder != b.folder) return a.folder ? -1 : 1;
      var result = 0;
      if (sort == FileSort.modified) {
        if (a.modified == null && b.modified != null) return 1;
        if (a.modified != null && b.modified == null) return -1;
        if (a.modified != null && b.modified != null) {
          result = a.modified!.compareTo(b.modified!);
        }
      }
      if (!a.folder) {
        if (sort == FileSort.size) result = a.size.compareTo(b.size);
        if (sort == FileSort.type) result = a.type.compareTo(b.type);
      }
      if (result == 0) result = a.name.compareTo(b.name);
      if (result == 0) return a.sequence.compareTo(b.sequence);
      return descending ? -result : result;
    }

    if (_sort != sort || _descending != descending) {
      _sorted = List.of(_all)..sort(compare);
    } else {
      final added = _all.sublist(_sorted.length)..sort(compare);
      if (_sorted.isEmpty || compare(_sorted.last, added.first) <= 0) {
        _sorted = [..._sorted, ...added];
      } else {
        final merged = <_EntryKey>[];
        var oldIndex = 0;
        var newIndex = 0;
        while (oldIndex < _sorted.length && newIndex < added.length) {
          if (compare(_sorted[oldIndex], added[newIndex]) <= 0) {
            merged.add(_sorted[oldIndex++]);
          } else {
            merged.add(added[newIndex++]);
          }
        }
        merged.addAll(_sorted.getRange(oldIndex, _sorted.length));
        merged.addAll(added.getRange(newIndex, added.length));
        _sorted = merged;
      }
    }
    _sort = sort;
    _descending = descending;
    return _snapshot = FileOrderSnapshot._(_sorted);
  }
}

/// Adapter for standalone widgets receiving immutable entry lists.
class FileOrderCache {
  List<Map<String, dynamic>>? _source;
  DirectoryOrder _order = DirectoryOrder();
  FileOrderSnapshot resolve(
    List<Map<String, dynamic>> source,
    FileSort sort,
    bool descending,
  ) {
    if (!identical(source, _source)) {
      _source = source;
      _order = DirectoryOrder()..add(source);
    }
    return _order.snapshot(sort, descending);
  }
}

List<Map<String, dynamic>> sortedFiles(
  List<Map<String, dynamic>> source,
  FileSort sort,
  bool descending,
) =>
    (DirectoryOrder()..add(source)).snapshot(sort, descending).entries.toList();

/// Neighbours follow the published directory order and never wrap.
Map<String, dynamic>? adjacentVideo(
  List<Map<String, dynamic>> entries,
  String? current,
  int step,
  FileSort sort,
  bool descending,
) => (DirectoryOrder()..add(entries))
    .snapshot(sort, descending)
    .adjacentVideo(current, step);
