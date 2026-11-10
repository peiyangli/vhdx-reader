String extension(String name) =>
    name.contains('.') ? name.split('.').last.toLowerCase() : '';
bool isText(String name) => [
  'txt',
  'md',
  'log',
  'json',
  'xml',
  'csv',
  'yaml',
  'yml',
  'ini',
  'toml',
  'rs',
  'dart',
  'py',
  'c',
  'h',
  'cpp',
  'js',
  'ts',
  'html',
  'css',
  'srt',
  'vtt',
].contains(extension(name));
bool isImage(String name) =>
    ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(extension(name));
bool isVideo(String name) => [
  'mp4',
  'mkv',
  'mov',
  'avi',
  'asf',
  'rm',
  'rmvb',
  'webm',
  'm4v',
  'wmv',
  'flv',
  'ts',
  'mts',
  'm2ts',
  '3gp',
].contains(extension(name));
int friendlyTypeOrder(String name) => const [
  '图片',
  '视频',
  '音频',
  'PDF',
  '文档',
  '压缩包',
  '文件',
].indexOf(friendlyType(name));

String friendlyType(String name) {
  if (isImage(name)) return '图片';
  if (isVideo(name)) return '视频';
  final ext = extension(name);
  if ([
    'mp3',
    'flac',
    'wav',
    'aac',
    'm4a',
    'ogg',
    'opus',
    'wma',
  ].contains(ext)) {
    return '音频';
  }
  if (ext == 'pdf') return 'PDF';
  if (['zip', '7z', 'rar', 'tar', 'gz', 'xz'].contains(ext)) return '压缩包';
  if ([
    'txt',
    'md',
    'json',
    'xml',
    'csv',
    'log',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
  ].contains(ext)) {
    return '文档';
  }
  return '文件';
}
