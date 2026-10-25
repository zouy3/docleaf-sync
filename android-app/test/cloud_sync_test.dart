import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/cloud_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CloudSync sync;
  late Map<String, Map<String, dynamic>> remote;
  late bool offline;
  Map<String, dynamic> position(int offset) => {
    'version': 1,
    'chapter_id': '456',
    'chapter_index': 0,
    'chapter_title': '第一章',
    'paragraph_id': '1',
    'ordinal': 0,
    'character_offset': offset,
    'quote': '中文正文',
  };
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    remote = {};
    offline = false;
    sync = CloudSync(
      client: MockClient((request) async {
        if (offline) throw Exception('offline');
        final payload = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map;
        Object result;
        if (request.url.path.contains('/auth/')) {
          result = {
            'access_token': payload['email'],
            'refresh_token': 'refresh',
            'expires_in': 3600,
            'user': {'id': payload['email']},
          };
        } else if (request.url.path.contains('/rpc/')) {
          final key =
              '${request.headers['Authorization']}:${payload['p_book_id']}';
          final previous = remote[key];
          if (previous != null &&
              payload['p_cursor'] != null &&
              previous['revision'] != payload['p_expected_revision']) {
            result = {'status': 'conflict', 'row': previous};
          } else {
            final row = <String, dynamic>{
              'book_id': payload['p_book_id'],
              'title': payload['p_title'],
              'author': '',
              'cover': '',
              'cursor': payload['p_cursor'] ?? previous?['cursor'],
              'revision': (previous?['revision'] as int? ?? 0) + 1,
              'device_id': payload['p_device_id'],
              'updated_at': '2026-10-25T00:00:00Z',
            };
            remote[key] = row;
            result = {'status': 'saved', 'row': row};
          }
        } else {
          result = remote.entries
              .where(
                (entry) => entry.key.startsWith(
                  '${request.headers['Authorization']}:',
                ),
              )
              .map((entry) => entry.value)
              .toList();
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await Future.wait([sync.init(), sync.init()]);
  });
  tearDown(() => sync.dispose());

  test('same stock account convention', () {
    expect(
      CloudSync.emailFor(' Reader_1 '),
      'reader_1@users.quiet-notes.invalid',
    );
    expect(() => CloudSync.emailFor('中文账号'), throwsException);
  });
  test('metadata upload preserves cursor', () async {
    await sync.login('reader', 'password');
    await sync.queue('123', '测试小说', '', '', position(25));
    await sync.sync();
    await sync.queue('123', '测试小说', '', '', null);
    await sync.sync();
    expect(sync.rows.single['cursor']['character_offset'], 25);
    expect(sync.pending, isEmpty);
  });
  test('offline queue isolated by account and flushed on return', () async {
    await sync.login('reader', 'password');
    offline = true;
    await sync.queue('123', '测试小说', '', '', position(40));
    await sync.sync();
    expect(sync.pending['123']['cursor']['character_offset'], 40);
    offline = false;
    await sync.login('another', 'password');
    expect(sync.pending, isEmpty);
    expect(sync.rows, isEmpty);
    await sync.login('reader', 'password');
    expect(sync.rows.single['cursor']['character_offset'], 40);
  });
  test('new remote position requires explicit conflict resolution', () async {
    await sync.login('reader', 'password');
    await sync.queue('123', '测试小说', '', '', position(10));
    await sync.sync();
    final row = remote.values.single;
    row['revision'] = 2;
    row['cursor'] = position(90);
    await sync.sync();
    await sync.queue('123', '测试小说', '', '', position(20));
    await sync.sync();
    expect(sync.conflicts['123']['cursor']['character_offset'], 90);
    await sync.resolve('123', false);
    expect(sync.pending, isEmpty);
    expect(sync.rows.single['cursor']['character_offset'], 90);
  });
}
