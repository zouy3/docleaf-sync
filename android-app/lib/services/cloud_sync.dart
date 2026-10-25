import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// This is our own sync service, independent of the upstream content API.
// Only the public project key is distributed; all writes require user JWT + RLS.
class CloudSync extends ChangeNotifier with WidgetsBindingObserver {
  CloudSync({http.Client? client}) : _client = client ?? http.Client();
  static final instance = CloudSync();
  static const url = 'https://vfuznbboqrxmrlirdwti.supabase.co';
  static const publicKey = 'sb_publishable_1OFiLFqzp9c3SSb0xdfriA_TF6bBAZF';
  static const _secure = FlutterSecureStorage();
  final http.Client _client;
  Map<String, dynamic>? session;
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic> pending = {}, conflicts = {};
  Map<String, dynamic> bases = {};
  String status = '未登录 · 本地阅读';
  bool _ready = false, _running = false;
  int _generation = 0, _sequence = 0;
  Timer? _timer, _periodic;
  Future<String>? _refreshing;
  Future<void>? _initializing;
  SharedPreferences? _prefs;
  String _device = '';
  String get deviceId => _device;
  String get account =>
      session?['user']?['user_metadata']?['username']?.toString() ?? '已登录';
  String get _accountKey => 'docleaf-sync:${session!['user']['id']}';

  Future<void> init() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    if (_ready) return;
    _prefs = await SharedPreferences.getInstance();
    try {
      session =
          jsonDecode(await _secure.read(key: 'docleaf-sync-session') ?? 'null')
              as Map<String, dynamic>?;
    } catch (_) {}
    _device =
        _prefs!.getString('docleaf-sync-device') ??
        'android-${DateTime.now().microsecondsSinceEpoch}';
    await _prefs!.setString('docleaf-sync-device', _device);
    _ready = true;
    _restore();
    WidgetsBinding.instance.addObserver(this);
    _periodic = Timer.periodic(const Duration(seconds: 20), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) {
        unawaited(sync());
      }
    });
    unawaited(sync());
  }

  void _restore() {
    rows = [];
    pending = {};
    conflicts = {};
    bases = {};
    if (session != null) {
      try {
        final data =
            jsonDecode(_prefs!.getString(_accountKey) ?? '{}')
                as Map<String, dynamic>;
        rows = (data['rows'] as List? ?? [])
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        pending = Map<String, dynamic>.from(data['pending'] as Map? ?? {});
        bases = Map<String, dynamic>.from(data['bases'] as Map? ?? {});
        for (final item in pending.values) {
          final sequence = (item['sequence'] as num?)?.toInt() ?? 0;
          if (sequence > _sequence) _sequence = sequence;
        }
      } catch (_) {}
    }
    status = session == null ? '未登录 · 本地阅读' : '已登录 · 等待同步';
    notifyListeners();
  }

  Future<void> _persist() async {
    if (session != null) {
      await _prefs!.setString(
        _accountKey,
        jsonEncode({'rows': rows, 'pending': pending, 'bases': bases}),
      );
    }
  }

  Future<void> acceptRemote(Map<String, dynamic> row) async {
    bases[row['book_id'] as String] = row['revision'];
    pending.remove(row['book_id']);
    conflicts.remove(row['book_id']);
    await _persist();
  }

  static String emailFor(String username) {
    final name = username.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]{3,32}$').hasMatch(name)) {
      throw Exception('用户名为 3–32 位字母、数字、下划线或短横线');
    }
    return '$name@users.quiet-notes.invalid';
  }

  Future<dynamic> _request(
    String path, {
    String method = 'GET',
    Object? body,
    String? token,
  }) async {
    final request = http.Request(method, Uri.parse('$url$path'));
    request.headers.addAll({
      'apikey': publicKey,
      if (token != null) 'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 15)),
    ).timeout(const Duration(seconds: 15));
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {}
    if (response.statusCode >= 400) {
      final code = data is Map ? data['code'] ?? data['error_code'] : null;
      throw Exception(
        ['PGRST205', 'PGRST202', '42P01'].contains(code)
            ? '云端尚未初始化，请运行 sync/schema.sql'
            : code == 'invalid_credentials'
            ? '用户名或密码错误'
            : data is Map
            ? (data['message'] ??
                  data['msg'] ??
                  data['error_description'] ??
                  '同步失败')
            : '同步失败',
      );
    }
    return data;
  }

  Future<void> login(
    String username,
    String password, {
    bool register = false,
  }) async {
    await init();
    final generation = ++_generation;
    final data = Map<String, dynamic>.from(
      await _request(
            register ? '/auth/v1/signup' : '/auth/v1/token?grant_type=password',
            method: 'POST',
            body: {
              'email': emailFor(username),
              'password': password,
              if (register) 'data': {'username': username.trim().toLowerCase()},
            },
          )
          as Map,
    );
    if (generation != _generation) return;
    if (data['access_token'] == null) throw Exception('账号需要邮箱确认，请检查项目设置');
    data['expires_at'] ??=
        DateTime.now().millisecondsSinceEpoch ~/ 1000 +
        (data['expires_in'] as num).toInt();
    session = data;
    await _secure.write(
      key: 'docleaf-sync-session',
      value: jsonEncode(session),
    );
    _restore();
    await sync();
  }

  Future<void> logout() async {
    await _persist();
    _generation++;
    _timer?.cancel();
    session = null;
    await _secure.delete(key: 'docleaf-sync-session');
    _restore();
  }

  Future<String> _token() async {
    if (session == null) throw Exception('请先登录');
    if ((session!['expires_at'] as num) >
        DateTime.now().millisecondsSinceEpoch / 1000 + 60) {
      return session!['access_token'] as String;
    }
    if (_refreshing != null) return _refreshing!;
    final generation = _generation;
    _refreshing = () async {
      final data = Map<String, dynamic>.from(
        await _request(
              '/auth/v1/token?grant_type=refresh_token',
              method: 'POST',
              body: {'refresh_token': session!['refresh_token']},
            )
            as Map,
      );
      if (generation != _generation) throw Exception('账号已切换');
      data['expires_at'] ??=
          DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          (data['expires_in'] as num).toInt();
      session = data;
      await _secure.write(key: 'docleaf-sync-session', value: jsonEncode(data));
      return data['access_token'] as String;
    }().whenComplete(() => _refreshing = null);
    return _refreshing!;
  }

  Future<void> queue(
    String id,
    String title,
    String author,
    String cover,
    Map<String, dynamic>? cursor,
  ) async {
    if (!_ready || session == null || !RegExp(r'^[0-9]{1,30}$').hasMatch(id)) {
      return;
    }
    final previous = pending[id] as Map?;
    pending[id] = {
      'book': {'book_id': id, 'title': title, 'author': author, 'cover': cover},
      'cursor': cursor ?? previous?['cursor'],
      'base': previous?['base'] ?? bases[id] ?? 0,
      'sequence': ++_sequence,
    };
    await _persist();
    status = '进度已保存本地 · 待同步';
    notifyListeners();
    _timer ??= Timer(const Duration(seconds: 5), () {
      _timer = null;
      unawaited(sync());
    });
  }

  Future<void> sync() async {
    if (!_ready || session == null || _running) return;
    _running = true;
    final generation = _generation;
    status = '正在同步…';
    notifyListeners();
    try {
      final token = await _token();
      if (generation != _generation) return;
      for (final entry in Map<String, dynamic>.from(pending).entries) {
        if (conflicts.containsKey(entry.key)) continue;
        final item = entry.value as Map, book = entry.value['book'] as Map;
        final result =
            await _request(
                  '/rest/v1/rpc/docleaf_save',
                  method: 'POST',
                  token: token,
                  body: {
                    'p_book_id': entry.key,
                    'p_title': book['title'],
                    'p_author': book['author'],
                    'p_cover': book['cover'],
                    'p_cursor': item['cursor'],
                    'p_expected_revision': item['base'],
                    'p_device_id': _device,
                  },
                )
                as Map;
        if (generation != _generation) return;
        final row = Map<String, dynamic>.from(result['row'] as Map);
        if (result['status'] == 'conflict') {
          conflicts[entry.key] = row;
          continue;
        }
        rows = [...rows.where((r) => r['book_id'] != entry.key), row];
        bases[entry.key] = row['revision'];
        if (pending[entry.key]?['sequence'] == item['sequence']) {
          pending.remove(entry.key);
        } else if (pending[entry.key] != null) {
          pending[entry.key]['base'] = row['revision'];
        }
        await _persist();
      }
      final fresh = <Map<String, dynamic>>[];
      for (var offset = 0; ; offset += 500) {
        final chunk =
            await _request(
                  '/rest/v1/docleaf_books?select=*&order=updated_at.desc&limit=500&offset=$offset',
                  token: token,
                )
                as List;
        if (generation != _generation) return;
        fresh.addAll(chunk.map((r) => Map<String, dynamic>.from(r as Map)));
        if (chunk.length < 500) break;
      }
      rows = fresh;
      await _persist();
      status = conflicts.isNotEmpty
          ? '进度冲突，请选择保留哪一份'
          : pending.isNotEmpty
          ? '仍有待同步记录'
          : '同步完成';
    } catch (e) {
      if (generation == _generation) status = '$e · 本地阅读不受影响';
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> resolve(String id, bool useLocal) async {
    if (conflicts[id] == null) return;
    if (useLocal && pending[id] != null) {
      pending[id]['base'] = conflicts[id]['revision'];
    } else {
      bases[id] = conflicts[id]['revision'];
      pending.remove(id);
    }
    conflicts.remove(id);
    await _persist();
    await sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _periodic?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _client.close();
    super.dispose();
  }
}
