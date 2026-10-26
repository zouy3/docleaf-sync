import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'platform_channel.dart';

enum UpdateChannel { stable, preview }

class UpdateDevice {
  const UpdateDevice(
    this.packageName,
    this.versionCode,
    this.versionName,
    this.abis,
  );
  final String packageName, versionName;
  final int versionCode;
  final List<String> abis;
  factory UpdateDevice.fromMap(Map value) => UpdateDevice(
    value['packageName'] as String,
    (value['versionCode'] as num).toInt(),
    value['versionName'] as String,
    List<String>.from(value['abis'] as List),
  );
}

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.code,
    required this.abi,
    required this.filename,
    required this.hash,
    required this.size,
    required this.download,
    required this.releaseUrl,
    required this.notes,
  });
  final String version, abi, filename, hash, notes;
  final int code, size;
  final Uri download, releaseUrl;

  static bool trustedAsset(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      uri.path.startsWith('/zouy3/docleaf-sync/releases/download/') &&
      uri.fragment.isEmpty;

  static AppUpdate? parse(Map manifest, Map release, UpdateDevice device) {
    if (manifest['schema'] != 1 ||
        manifest['packageName'] != device.packageName ||
        device.packageName != 'com.fqapp.fqapp') {
      throw const FormatException('更新包标识不正确');
    }
    final code = manifest['versionCode'];
    final version = manifest['versionName'];
    if (code is! int ||
        code < 1 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const FormatException('更新版本信息不正确');
    }
    if (code <= device.versionCode) return null;
    final assets = release['assets'] as List;
    for (final abi in device.abis) {
      final entries = (manifest['assets'] as List)
          .where((a) => a is Map && a['abi'] == abi)
          .toList();
      if (entries.isEmpty) continue;
      if (entries.length != 1) throw const FormatException('更新包架构重复');
      final a = entries.single as Map;
      final name = 'DocLeaf-Sync-$version-$abi.apk';
      if (a['name'] != name ||
          a['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(a['sha256'] as String) ||
          a['size'] is! int ||
          (a['size'] as int) < 1 ||
          (a['size'] as int) > 200 * 1024 * 1024) {
        throw const FormatException('更新文件信息不正确');
      }
      final matches = assets
          .where(
            (v) => v is Map && v['name'] == name && v['state'] == 'uploaded',
          )
          .toList();
      if (matches.length != 1) throw const FormatException('更新文件尚未发布完整');
      final remote = matches.single as Map;
      final uri = Uri.parse(remote['browser_download_url'] as String);
      if (!trustedAsset(uri) ||
          uri.pathSegments.last != name ||
          remote['size'] != a['size']) {
        throw const FormatException('更新文件来源不正确');
      }
      final digest = remote['digest'];
      if (digest != null && digest != 'sha256:${a['sha256']}') {
        throw const FormatException('更新文件校验信息冲突');
      }
      final releaseUrl = Uri.parse(release['html_url'] as String);
      if (releaseUrl.scheme != 'https' ||
          releaseUrl.host != 'github.com' ||
          !releaseUrl.path.startsWith('/zouy3/docleaf-sync/releases/tag/')) {
        throw const FormatException('更新页面来源不正确');
      }
      return AppUpdate(
        version: version,
        code: code,
        abi: abi,
        filename: name,
        hash: a['sha256'] as String,
        size: a['size'] as int,
        download: uri,
        releaseUrl: releaseUrl,
        notes: (release['body'] as String? ?? '').substring(
          0,
          (release['body'] as String? ?? '').length.clamp(0, 12000),
        ),
      );
    }
    return null;
  }
}

// Separate storage keys and cache directory: never migrate/delete reading or
// secure account data. The service has no dependency on either store.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService({
    http.Client? client,
    http.Client Function()? downloadClient,
    this.deviceLoader,
    Future<Directory> Function()? directory,
  }) : _client = client ?? http.Client(),
       _downloadFactory = downloadClient ?? (() => http.Client()),
       _directory = directory ?? getTemporaryDirectory;
  static final instance = AppUpdateService();
  static const platform = AppMethodChannel('docleaf/update');
  final http.Client _client;
  final http.Client Function() _downloadFactory;
  final Future<UpdateDevice> Function()? deviceLoader;
  final Future<Directory> Function() _directory;
  Future<void>? _initializing;
  SharedPreferences? _prefs;
  UpdateDevice? device;
  AppUpdate? candidate;
  File? apk;
  UpdateChannel channel = UpdateChannel.preview;
  bool checking = false, downloading = false, installing = false;
  bool _changingChannel = false;
  bool get busy => checking || downloading || installing || _changingChannel;
  int received = 0, total = 0, _downloadGeneration = 0;
  http.Client? _downloader;
  String status = '尚未检查更新', error = '';
  bool get supported => Platform.isAndroid || deviceLoader != null;

  Future<void> initialize({bool autoCheck = false}) async {
    if (!supported) {
      status = '应用内安装仅支持 Android';
      return;
    }
    await (_initializing ??= _initialize().catchError((Object e) {
      _initializing = null;
      throw e;
    }));
    if (autoCheck && !busy) {
      final value = _prefs!.get('docleaf_update_last_attempt');
      final now = DateTime.now().millisecondsSinceEpoch;
      if (value is! int ||
          value > now ||
          now - value > const Duration(days: 1).inMilliseconds) {
        await check();
      }
    }
  }

  Future<void> _initialize() async {
    _prefs = await SharedPreferences.getInstance();
    channel = _prefs!.get('docleaf_update_preview') == false
        ? UpdateChannel.stable
        : UpdateChannel.preview;
    device = deviceLoader != null
        ? await deviceLoader!()
        : UpdateDevice.fromMap(
            (await platform.invokeMapMethod<dynamic, dynamic>('info'))!,
          );
    notifyListeners();
  }

  Future<void> setChannel(UpdateChannel value) async {
    if (busy) return;
    _changingChannel = true;
    notifyListeners();
    try {
      await initialize();
      if (_prefs == null) return;
      channel = value;
      candidate = null;
      apk = null;
      error = '';
      await _prefs!.setBool(
        'docleaf_update_preview',
        value == UpdateChannel.preview,
      );
    } catch (e) {
      error = '无法保存更新渠道：$e';
      return;
    } finally {
      _changingChannel = false;
      notifyListeners();
    }
    await check();
  }

  Future<dynamic> _json(Uri uri, {int limit = 512 * 1024}) async {
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'DocLeaf-Sync-Android',
      });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException(
        response.statusCode == 403 || response.statusCode == 429
            ? 'GitHub 访问受限，请稍后重试'
            : '更新服务返回 ${response.statusCode}',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('更新信息过大');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  Future<void> check() async {
    if (busy || !supported) return;
    checking = true;
    error = '';
    status = '正在检查更新…';
    notifyListeners();
    try {
      await initialize();
      await _prefs!.setInt(
        'docleaf_update_last_attempt',
        DateTime.now().millisecondsSinceEpoch,
      );
      AppUpdate? best;
      for (var page = 1; page <= 3; page++) {
        final releases =
            await _json(
                  Uri.parse(
                    'https://api.github.com/repos/zouy3/docleaf-sync/releases?per_page=10&page=$page',
                  ),
                )
                as List;
        for (final r in releases.whereType<Map>()) {
          if (r['draft'] != false ||
              (channel == UpdateChannel.stable && r['prerelease'] != false)) {
            continue;
          }
          final assets = r['assets'] as List? ?? [];
          final manifests = assets
              .where(
                (a) =>
                    a is Map &&
                    a['name'] == 'android-update.json' &&
                    a['state'] == 'uploaded',
              )
              .toList();
          if (manifests.isEmpty) {
            continue; // Web-only and older releases are not Android updates.
          }
          if (manifests.length != 1) throw const FormatException('更新清单重复');
          final uri = Uri.parse(
            (manifests.single as Map)['browser_download_url'] as String,
          );
          if (!AppUpdate.trustedAsset(uri) ||
              uri.pathSegments.last != 'android-update.json') {
            throw const FormatException('更新清单来源不正确');
          }
          final manifest = await _json(uri, limit: 64 * 1024) as Map;
          final next = AppUpdate.parse(manifest, r, device!);
          if (next != null && (best == null || next.code > best.code)) {
            best = next;
          }
        }
        if (releases.length < 10) break;
      }
      candidate = best;
      apk = null;
      status = best == null ? '当前渠道暂无更高版本' : '发现新版本 ${best.version}';
    } catch (e) {
      error = '检查失败：$e';
      status = '本地阅读不受影响，可稍后重试';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<bool> _verified(File file, AppUpdate update) async =>
      await file.exists() &&
      await file.length() == update.size &&
      (await sha256.bind(file.openRead()).first).toString() == update.hash;

  Future<void> download() async {
    final update = candidate;
    if (busy || update == null) return;
    downloading = true;
    error = '';
    received = 0;
    total = update.size;
    apk = null;
    final generation = ++_downloadGeneration;
    status = '正在下载更新…';
    notifyListeners();
    final client = _downloadFactory();
    _downloader = client;
    try {
      final folder = Directory('${(await _directory()).path}/docleaf-updates');
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/${update.code}-${update.abi}-${update.hash.substring(0, 12)}.apk',
      );
      if (await _verified(file, update)) {
        apk = file;
        status = '更新包已校验，可以安装';
        return;
      }
      final partial = File('${file.path}.part');
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > update.size) {
        await partial.delete();
        offset = 0;
      }
      if (offset < update.size) {
        final request = http.Request('GET', update.download);
        if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 25));
        if (response.statusCode == 200) {
          offset = 0;
        } else if (response.statusCode == 206 && offset > 0) {
          final range = RegExp(
            r'^bytes (\d+)-(\d+)/(\d+)$',
          ).firstMatch(response.headers['content-range'] ?? '');
          if (range == null ||
              int.parse(range[1]!) != offset ||
              int.parse(range[3]!) != update.size ||
              int.parse(range[2]!) >= update.size) {
            throw const FormatException('断点下载响应不正确');
          }
        } else {
          throw HttpException('下载失败：${response.statusCode}');
        }
        received = offset;
        final sink = partial.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        try {
          var lastNotice = DateTime.fromMillisecondsSinceEpoch(0);
          await sink.addStream(
            response.stream.timeout(const Duration(seconds: 30)).map((bytes) {
              if (generation != _downloadGeneration) {
                throw const HttpException('下载已取消');
              }
              received += bytes.length;
              if (received > update.size) {
                throw const FormatException('下载文件大小超出预期');
              }
              final now = DateTime.now();
              if (now.difference(lastNotice).inMilliseconds > 150) {
                lastNotice = now;
                notifyListeners();
              }
              return bytes;
            }),
          );
        } finally {
          await sink.close();
        }
      }
      if (generation != _downloadGeneration) return;
      status = '正在校验更新包…';
      notifyListeners();
      if (!await _verified(partial, update)) {
        if (await partial.exists()) await partial.delete();
        throw const FormatException('文件不完整或 SHA-256 不匹配，请重试');
      }
      if (await file.exists()) await file.delete();
      apk = await partial.rename(file.path);
      received = update.size;
      status = '校验通过，点击安装更新';
    } catch (e) {
      if (generation == _downloadGeneration) {
        error = '下载失败：$e';
        status = '可重试下载，已有断点会尽量保留';
      }
    } finally {
      client.close();
      if (identical(_downloader, client)) _downloader = null;
      downloading = false;
      notifyListeners();
    }
  }

  void cancelDownload() {
    if (!downloading) return;
    _downloadGeneration++;
    _downloader?.close();
    status = '已取消，可继续下载';
    notifyListeners();
  }

  Future<bool> install() async {
    if (busy || candidate == null || apk == null) return false;
    installing = true;
    error = '';
    notifyListeners();
    try {
      if (!await _verified(apk!, candidate!)) {
        apk = null; // Cache eviction/corruption must offer Download again.
        throw const FormatException('文件校验失败，请重新下载');
      }
      final result = await platform.invokeMethod<String>('install', {
        'path': apk!.path,
        'versionCode': candidate!.code,
      });
      if (result == 'permission_required') {
        status = '请允许本应用安装更新，再返回点击安装';
        return false;
      }
      if (result != 'started') throw const FormatException('系统安装器未启动');
      status = '请在系统界面确认安装；取消后可再次安装';
      return true;
    } catch (e) {
      error = '无法安装：$e';
      return false;
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  Future<void> openInstallPermission() =>
      platform.invokeMethod<void>('permission');
  @override
  void dispose() {
    _downloadGeneration++;
    _downloader?.close();
    _client.close();
    super.dispose();
  }
}
