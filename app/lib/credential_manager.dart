import 'package:flutter/material.dart';
import 'backend.dart';

class CredentialManager extends StatefulWidget {
  const CredentialManager({super.key, required this.backend});
  final ReaderBackend backend;
  @override
  State<CredentialManager> createState() => _CredentialManagerState();
}

class _CredentialManagerState extends State<CredentialManager> {
  List<Map<String, dynamic>> _entries = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final result = await widget.backend.request({'op': 'vault_list'});
      if (!mounted) return;
      setState(() {
        _entries = (result['entries'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _error = result['available'] == false ? '此平台尚未提供安全存储，解锁信息不会保存。' : null;
      });
    } on ReaderFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取安全存储，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String? id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(id == null ? '清除全部解锁信息？' : '删除这条解锁信息？'),
        content: const Text('下次打开需要重新输入密码。已经打开的分区仍保持解锁。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.backend.request(
        id == null ? {'op': 'vault_clear'} : {'op': 'vault_remove', 'id': id},
      );
      await _refresh();
    } on ReaderFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('已保存的解锁信息'),
      content: SizedBox(
        width: 520,
        height: 330,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '凭据仅保存在本设备。移动或重命名镜像不会影响识别。',
                    style: TextStyle(fontSize: 12),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  Expanded(
                    child: _entries.isEmpty
                        ? const Center(child: Text('没有已保存的解锁信息'))
                        : ListView.builder(
                            itemCount: _entries.length,
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  entry['label'] as String,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${entry['mode'] == 'recovery' ? '恢复密钥' : '密码'} · ${(entry['id'] as String).substring(3, 15)}',
                                ),
                                trailing: IconButton(
                                  tooltip: '删除记录',
                                  onPressed: () =>
                                      _remove(entry['id'] as String),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _remove(null),
          child: const Text('清除全部'),
        ),
        TextButton(onPressed: _busy ? null : _refresh, child: const Text('刷新')),
        FilledButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}
