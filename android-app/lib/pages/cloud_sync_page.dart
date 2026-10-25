import 'dart:async';
import 'package:flutter/material.dart';
import '../services/cloud_sync.dart';
import '../services/library_store.dart';
import '../services/shelf_store.dart';
import '../models/media_item.dart';
import 'detail_page.dart';

class CloudSyncPage extends StatefulWidget {
  const CloudSyncPage({super.key});
  @override
  State<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends State<CloudSyncPage> {
  final _name = TextEditingController(), _password = TextEditingController();
  final _cloud = CloudSync.instance;
  bool _busy = false, _register = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    _cloud.addListener(_changed);
    unawaited(_cloud.init());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _merge() async {
    for (final record in ShelfStore.instance.records()) {
      final item = record.item;
      if (item.kind == 'book' &&
          !_cloud.rows.any((r) => r['book_id'] == item.id)) {
        await _cloud.queue(item.id, item.title, item.author, item.cover, null);
      }
    }
    await _cloud.sync();
  }

  Future<void> _open(Map<String, dynamic> row) async {
    await _cloud.acceptRemote(row);
    final id = row['book_id'] as String, cursor = row['cursor'] as Map?;
    final item = MediaItem(
      id: id,
      title: row['title'] as String,
      author: row['author'] as String? ?? '',
      cover: row['cover'] as String? ?? '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    await ShelfStore.instance.add(item);
    if (cursor != null) {
      await LibraryStore.instance.addHistory({
        'id': id,
        'bookId': id,
        'kind': 'book',
        'title': item.title,
        'cover': item.cover,
        'chapterId': cursor['chapter_id'],
        'episode': cursor['chapter_index'],
        'positionVersion': 2,
        'textOffset': 0,
        'position': 0.0,
        'maxScroll': 0.0,
        'progress': 0.0,
        'time': DateTime.now().millisecondsSinceEpoch,
        'cloudCursor': Map<String, dynamic>.from(cursor),
      });
    }
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => DetailPage(item: item)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('账号与阅读同步')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('与网页端、股票工具共用账号。只同步番茄书架和阅读位置，不上传正文和评论。'),
        const SizedBox(height: 16),
        if (_cloud.session == null) ...[
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '用户名'),
            autofillHints: const [AutofillHints.username],
          ),
          TextField(
            controller: _password,
            decoration: const InputDecoration(labelText: '密码'),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _cloud.login(
                      _name.text,
                      _password.text,
                      register: _register,
                    );
                    _password.clear();
                  }),
            child: Text(
              _busy
                  ? '请稍候…'
                  : _register
                  ? '创建账号'
                  : '登录',
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() => _register = !_register),
            child: Text(_register ? '已有账号，去登录' : '没有账号，注册'),
          ),
        ] else ...[
          Text('当前账号：${_cloud.account}'),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_cloud.sync),
                child: const Text('立即同步'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _run(_merge),
                child: const Text('合并本地书架'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _run(_cloud.logout),
                child: const Text('退出登录'),
              ),
            ],
          ),
          for (final entry in _cloud.conflicts.entries)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${entry.value['title']}：另一设备有更新，当前设备也有未同步进度。'),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () => _cloud.resolve(entry.key, false),
                                ),
                          child: const Text('保留云端进度'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _run(() => _cloud.resolve(entry.key, true)),
                          child: const Text('使用本机进度'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const Divider(),
          const Text('云端书架'),
          for (final row in _cloud.rows)
            ListTile(
              title: Text(row['title'] as String),
              subtitle: Text(
                row['cursor']?['chapter_title'] as String? ?? '尚未阅读',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy || _cloud.conflicts.containsKey(row['book_id'])
                  ? null
                  : () => _run(() => _open(row)),
            ),
        ],
        const SizedBox(height: 16),
        Text(_cloud.status),
        if (_error.isNotEmpty)
          Text(
            _error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 12),
        const Text('网络不可达时继续本地阅读，联网后补传。若提示云端尚未初始化，请先运行项目中的 sync/schema.sql。'),
      ],
    ),
  );
  @override
  void dispose() {
    _cloud.removeListener(_changed);
    _name.dispose();
    _password.dispose();
    super.dispose();
  }
}
