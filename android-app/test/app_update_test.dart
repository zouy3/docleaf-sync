import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/app_update.dart';

const device = UpdateDevice('com.fqapp.fqapp', 137, '1.0.132', [
  'arm64-v8a',
  'armeabi-v7a',
]);
final payload = utf8.encode('APK update fixture');
Map<String, dynamic> manifest({int code = 138}) => {
  'schema': 1,
  'packageName': 'com.fqapp.fqapp',
  'versionName': '1.0.133',
  'versionCode': code,
  'assets': [
    {
      'abi': 'arm64-v8a',
      'versionCode': code,
      'name': 'DocLeaf-Sync-1.0.133-arm64-v8a.apk',
      'sha256': sha256.convert(payload).toString(),
      'size': payload.length,
    },
  ],
};
Map<String, dynamic> release({bool preview = true, bool android = true}) => {
  'draft': false,
  'prerelease': preview,
  'body': '更新说明',
  'html_url': 'https://github.com/zouy3/docleaf-sync/releases/tag/v133',
  'assets': [
    if (android)
      {
        'name': 'android-update.json',
        'state': 'uploaded',
        'browser_download_url':
            'https://github.com/zouy3/docleaf-sync/releases/download/v133/android-update.json',
      },
    {
      'name': 'DocLeaf-Sync-1.0.133-arm64-v8a.apk',
      'state': 'uploaded',
      'size': payload.length,
      'digest': 'sha256:${sha256.convert(payload)}',
      'browser_download_url':
          'https://github.com/zouy3/docleaf-sync/releases/download/v133/DocLeaf-Sync-1.0.133-arm64-v8a.apk',
    },
  ],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final services = <AppUpdateService>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 27,
      'theme_mode': 'dark',
      'docleaf-sync:account': 'keep-existing-data',
    });
    temp = await Directory.systemTemp.createTemp('docleaf-updates-test-');
  });
  tearDown(() async {
    for (final s in services) {
      s.dispose();
    }
    services.clear();
    await temp.delete(recursive: true);
  });
  AppUpdateService create({
    List<Map<String, dynamic>>? releases,
    http.Client Function()? downloader,
    void Function()? onList,
  }) {
    final client = MockClient((r) async {
      if (r.url.host == 'api.github.com') {
        onList?.call();
        return http.Response(
          jsonEncode(releases ?? [release()]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        jsonEncode(manifest()),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = AppUpdateService(
      client: client,
      deviceLoader: () async => device,
      directory: () async => temp,
      downloadClient:
          downloader ??
          () => MockClient((_) async => http.Response.bytes(payload, 200)),
    );
    services.add(service);
    return service;
  }

  test('selects compatible APK and rejects equal version or other package', () {
    final update = AppUpdate.parse(manifest(), release(), device)!;
    expect(update.code, 138);
    expect(update.abi, 'arm64-v8a');
    expect(AppUpdate.parse(manifest(code: 137), release(), device), isNull);
    final wrong = manifest()..['packageName'] = 'other';
    expect(
      () => AppUpdate.parse(wrong, release(), device),
      throwsFormatException,
    );
    expect(
      AppUpdate.parse(
        manifest(),
        release(),
        const UpdateDevice('com.fqapp.fqapp', 137, '1.0.132', ['x86_64']),
      ),
      isNull,
    );
  });
  test('split APK installation code is distinct from base release code', () {
    final m = manifest();
    (m['assets'] as List)[0]['versionCode'] = 2138;
    const installed = UpdateDevice('com.fqapp.fqapp', 2137, '1.0.132', [
      'arm64-v8a',
    ], baseCode: 137);
    final next = AppUpdate.parse(m, release(), installed)!;
    expect(next.code, 138);
    expect(next.apkVersionCode, 2138);
    expect(
      AppUpdate.parse(
        m,
        release(),
        const UpdateDevice('com.fqapp.fqapp', 2138, '1.0.133', [
          'arm64-v8a',
        ], baseCode: 138),
      ),
      isNull,
    );
  });
  test('rejects foreign URL, mismatched size and conflicting digest', () {
    final r = release();
    (r['assets'] as List)[1]['browser_download_url'] =
        'https://example.com/evil.apk';
    expect(() => AppUpdate.parse(manifest(), r, device), throwsFormatException);
    final wrongSize = manifest();
    (wrongSize['assets'] as List)[0]['size'] = 100;
    expect(
      () => AppUpdate.parse(wrongSize, release(), device),
      throwsFormatException,
    );
    final wrongHash = release();
    (wrongHash['assets'] as List)[1]['digest'] = 'sha256:${'0' * 64}';
    expect(
      () => AppUpdate.parse(manifest(), wrongHash, device),
      throwsFormatException,
    );
  });
  test(
    'preview channel accepts Android prereleases and ignores web-only releases',
    () async {
      final s = create(releases: [release(android: false), release()]);
      await s.check();
      expect(s.candidate?.code, 138);
      expect(s.error, isEmpty);
      await s.setChannel(UpdateChannel.stable);
      expect(s.candidate, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('reader_font_size'), 27);
      expect(prefs.getString('docleaf-sync:account'), 'keep-existing-data');
      expect(prefs.getString('theme_mode'), 'dark');
    },
  );
  test('stable channel still finds stable Android release', () async {
    final s = create(releases: [release(preview: false)]);
    await s.setChannel(UpdateChannel.stable);
    expect(s.candidate?.code, 138);
  });
  test('automatic check is throttled without disabling manual retry', () async {
    var requests = 0;
    final s = create(onList: () => requests++);
    await s.initialize(autoCheck: true);
    await s.initialize(autoCheck: true);
    expect(requests, 1);
    await s.check();
    expect(requests, 2);
  });
  test(
    'download verifies hash and only invokes installer after explicit action',
    () async {
      var installs = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('docleaf/update'), (
            call,
          ) async {
            if (call.method == 'install') {
              installs++;
              expect((call.arguments as Map)['versionCode'], 138);
              return 'started';
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('docleaf/update'),
              null,
            ),
      );
      final s = create();
      await s.check();
      await s.download();
      expect(s.error, isEmpty);
      expect(await s.apk!.readAsBytes(), payload);
      expect(installs, 0);
      expect(await s.install(), true);
      expect(installs, 1);
      await s.apk!.writeAsBytes([0]);
      expect(await s.install(), false);
      expect(installs, 1);
      expect(s.apk, isNull);
    },
  );
  test('corrupt APK never becomes installable', () async {
    final s = create(
      downloader: () => MockClient(
        (_) async => http.Response.bytes(List.filled(payload.length, 0), 200),
      ),
    );
    await s.check();
    await s.download();
    expect(s.apk, isNull);
    expect(s.error, contains('SHA-256'));
    expect(await s.install(), false);
  });
  test(
    'range resume and servers that ignore range both produce exact APK',
    () async {
      for (final honorRange in [true, false]) {
        String? range;
        final s = create(
          downloader: () => MockClient((r) async {
            range = r.headers['Range'];
            return honorRange
                ? http.Response.bytes(
                    payload.sublist(4),
                    206,
                    headers: {
                      'content-range':
                          'bytes 4-${payload.length - 1}/${payload.length}',
                    },
                  )
                : http.Response.bytes(payload, 200);
          }),
        );
        await s.check();
        final u = s.candidate!;
        final folder = Directory('${temp.path}/docleaf-updates');
        await folder.create(recursive: true);
        final path =
            '${folder.path}/${u.code}-${u.abi}-${u.hash.substring(0, 12)}.apk';
        final complete = File(path);
        if (await complete.exists()) await complete.delete();
        await File('$path.part').writeAsBytes(payload.sublist(0, 4));
        await s.download();
        expect(range, 'bytes=4-');
        expect(s.error, isEmpty);
        expect(await s.apk!.readAsBytes(), payload);
      }
    },
  );
  test('wrong content-range does not append or install', () async {
    final s = create(
      downloader: () => MockClient(
        (_) async => http.Response.bytes(
          payload.sublist(4),
          206,
          headers: {
            'content-range': 'bytes 0-${payload.length - 1}/${payload.length}',
          },
        ),
      ),
    );
    await s.check();
    final u = s.candidate!;
    final folder = Directory('${temp.path}/docleaf-updates');
    await folder.create(recursive: true);
    final partial = File(
      '${folder.path}/${u.code}-${u.abi}-${u.hash.substring(0, 12)}.apk.part',
    );
    await partial.writeAsBytes(payload.sublist(0, 4));
    await s.download();
    expect(s.apk, isNull);
    expect(s.error, contains('断点'));
    expect(await partial.length(), 4);
  });
  test('network errors are retryable and preserve old settings', () async {
    final s = AppUpdateService(
      client: MockClient((_) async => throw const SocketException('offline')),
      deviceLoader: () async => device,
      directory: () async => temp,
    );
    services.add(s);
    await s.check();
    expect(s.error, isNotEmpty);
    expect(s.checking, false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('reader_font_size'), 27);
  });
}
