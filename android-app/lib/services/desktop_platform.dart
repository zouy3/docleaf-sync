import 'package:screen_retriever/screen_retriever.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/desktop_login.dart';
import 'platform_channel.dart';

bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// On Windows an inactive window is still visible; it simply lacks input focus.
/// Only hidden/paused/detached windows should defer foreground video playback.
bool playbackAppIsActive(AppLifecycleState? state) =>
    state == null ||
    state == AppLifecycleState.resumed ||
    (isWindowsDesktop && state == AppLifecycleState.inactive);

class DesktopPlatform with WindowListener {
  DesktopPlatform._();
  static final instance = DesktopPlatform._();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final readerBrightness = ValueNotifier<double>(1);
  static final fullscreen = ValueNotifier<bool>(false);
  final _events = <String, StreamController<dynamic>>{};
  bool _closing = false;
  Future<void> Function()? beforeClose;
  bool _readerAwake = false;
  String? _readerSession;
  Timer? _readerTimer;

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;
  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (!isWindowsDesktop) return;
    await windowManager.ensureInitialized();
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    final display = await screenRetriever.getPrimaryDisplay();
    final available = display.visibleSize ?? display.size;
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(min(1280, available.width), min(800, available.height)),
        minimumSize: Size(
          min(800, available.width),
          min(440, available.height),
        ),
        center: true,
        title: '番茄小铺 · 电脑版',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  Future<void> setFullscreen(bool value) async {
    await windowManager.setFullScreen(value);
    fullscreen.value = value;
  }

  @override
  void onWindowLeaveFullScreen() {
    fullscreen.value = false;
  }

  @override
  void onWindowEnterFullScreen() {
    fullscreen.value = true;
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      try {
        await beforeClose?.call();
      } catch (_) {}
      _readerTimer?.cancel();
      _readerAwake = false;
      _updateAwake();
    } finally {
      await windowManager.destroy();
    }
  }

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async {
    final args = arguments is Map ? arguments : const <dynamic, dynamic>{};
    switch (channel) {
      case 'fqapp/library_backup':
        return _backup(method, args);
      case 'fqapp/local_books':
        if (method == 'pickBookFile') return _pickBook();
      case 'fqapp/downloads':
        if (method == 'saveText') {
          final path = await _save(
            args['fileName'] as String,
            Uint8List.fromList(utf8.encode(args['text'] as String)),
            ['txt'],
          );
          if (path == null) {
            throw PlatformException(code: 'cancelled', message: '已取消保存');
          }
          return {'path': path, 'public': true};
        }
      case 'fqapp/reader':
        return _reader(method, args);
      case 'fqapp/fanqie_account':
        if (method == 'login') {
          final context = navigatorKey.currentContext;
          if (context == null) {
            throw PlatformException(code: 'not_ready', message: '窗口尚未就绪');
          }
          return DesktopLogin.open(context);
        }
        if (method == 'cancelLogin') {
          DesktopLogin.cancel();
          return null;
        }
        if (method == 'clearSession') {
          await DesktopLogin.clearSession();
          return null;
        }
      case 'fqapp/eink-refresh':
        return false;
      case 'fqapp/volume-key':
        return null;
      case 'fqapp/fair_memory':
        return null;
    }
    throw MissingPluginException('$channel/$method');
  }

  Future<dynamic> _reader(String method, Map args) async {
    switch (method) {
      case 'start':
        _readerSession = args['session'] as String?;
        _readerTimer?.cancel();
        _readerTimer = Timer.periodic(
          const Duration(minutes: 1),
          (_) => _emit('fqapp/reader/events', _readerStatus()),
        );
        _setBrightness(args['brightness']);
        return _readerStatus();
      case 'setBrightness':
        _setBrightness(args['brightness']);
        return true;
      case 'keepScreenOn':
        _readerAwake = args['on'] == true;
        _updateAwake();
        return null;
      case 'stop':
      case 'suspend':
        _readerTimer?.cancel();
        readerBrightness.value = 1;
        _readerAwake = false;
        _updateAwake();
        return null;
      case 'setImmersive':
        return null;
      case 'pickFont':
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '字体', extensions: ['ttf', 'otf', 'ttc']),
          ],
        );
        if (file == null) return null;
        if (await file.length() > 32 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '字体不能超过 32 MB');
        }
        final root = await getApplicationSupportDirectory();
        final fonts = await Directory(
          '${root.path}/fonts',
        ).create(recursive: true);
        final target = File(
          '${fonts.path}/${DateTime.now().microsecondsSinceEpoch}-${_safeName(file.name)}',
        );
        await File(file.path).copy(target.path);
        return {'path': target.path, 'name': file.name};
    }
    return null;
  }

  void _setBrightness(dynamic raw) {
    final value = raw is num ? raw.toDouble() : -1.0;
    readerBrightness.value = value < 0 ? 1 : value.clamp(.05, 1);
  }

  Map<String, dynamic> _readerStatus() => {
    'session': _readerSession,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'systemBrightness': 1.0,
  };
  void _updateAwake() {
    final call = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'SetThreadExecutionState',
        );
    call(0x80000000 | (_readerAwake ? 3 : 0));
  }

  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  Future<String?> _save(
    String name,
    Uint8List bytes,
    List<String> extensions,
  ) async {
    final location = await getSaveLocation(
      suggestedName: _safeName(name),
      acceptedTypeGroups: [XTypeGroup(label: '文件', extensions: extensions)],
    );
    if (location == null) return null;
    await XFile.fromData(bytes, name: name).saveTo(location.path);
    return location.path;
  }

  Future<Directory> _captureDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/fanqie_capture').create(recursive: true);
  }

  bool _validPart(String name) =>
      RegExp(r'^part-[0-9]+-[a-fA-F0-9-]+\.json$').hasMatch(name);
  Future<dynamic> _backup(String method, Map args) async {
    switch (method) {
      case 'saveBackup':
        return await _save(args['name'] as String, args['bytes'] as Uint8List, [
              'json',
            ]) !=
            null;
      case 'openBackup':
        final selected = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: '备份文件', extensions: ['json']),
          ],
        );
        if (selected == null) return null;
        if (await selected.length() > 128 * 1024 * 1024) {
          throw PlatformException(code: 'file_size', message: '备份文件过大');
        }
        return selected.readAsBytes();
      case 'storeFanqieCapture':
        final root = await _captureDirectory();
        final temp = File('${root.path}/latest.tmp');
        await temp.writeAsBytes(args['bytes'] as Uint8List, flush: true);
        await temp.rename('${root.path}/latest.json');
        return true;
      case 'latestFanqieCapture':
        final root = await _captureDirectory();
        final file = File('${root.path}/latest.json');
        return await file.exists() ? file.readAsBytes() : null;
      case 'storeFanqieCapturePart':
        final root = await _captureDirectory();
        final random = Random.secure();
        final suffix = List.generate(
          12,
          (_) => random.nextInt(16).toRadixString(16),
        ).join();
        final name =
            'part-${DateTime.now().microsecondsSinceEpoch}-$suffix.json';
        await File(
          '${root.path}/$name',
        ).writeAsBytes(args['bytes'] as Uint8List, flush: true);
        return name;
      case 'readFanqieCapturePart':
        final name = args['name'] as String;
        if (!_validPart(name)) {
          throw PlatformException(code: 'invalid_part', message: '分卷名称无效');
        }
        final root = await _captureDirectory();
        final file = File('${root.path}/$name');
        return await file.exists() ? file.readAsBytes() : null;
      case 'exportFanqieCapture':
        final root = await _captureDirectory();
        final archive = Archive();
        final bytes = args['bytes'] as Uint8List;
        archive.addFile(ArchiveFile('capture.json', bytes.length, bytes));
        for (final name in (args['parts'] as List).cast<String>().toSet()) {
          if (!_validPart(name)) throw PlatformException(code: 'invalid_part');
          final bytes = await File('${root.path}/$name').readAsBytes();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
        return await _save(
              args['name'] as String,
              Uint8List.fromList(ZipEncoder().encode(archive)),
              ['zip'],
            ) !=
            null;
    }
    throw MissingPluginException(method);
  }

  Future<Map<String, dynamic>?> _pickBook() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '本地书籍', extensions: ['txt', 'epub']),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 32 * 1024 * 1024) {
      throw PlatformException(code: 'file_size', message: '书籍不能超过 32 MB');
    }
    final bytes = await file.readAsBytes();
    return {
      'name': file.name,
      'bytes': bytes,
      'byteLength': bytes.length,
      if (file.name.toLowerCase().endsWith('.txt'))
        'text': decodeDesktopText(bytes),
    };
  }
}

String decodeDesktopText(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    final little = bytes[0] == 255;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
  } on FormatException {
    final convert = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(
            Uint32,
            Uint32,
            Pointer<Uint8>,
            Int32,
            Pointer<Uint16>,
            Int32,
          ),
          int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
        >('MultiByteToWideChar');
    final input = calloc<Uint8>(bytes.length);
    input.asTypedList(bytes.length).setAll(0, bytes);
    Pointer<Uint16> output = nullptr;
    try {
      final length = convert(54936, 0, input, bytes.length, nullptr, 0);
      if (length == 0) throw const FormatException('无法识别 TXT 编码');
      output = calloc<Uint16>(length);
      if (convert(54936, 0, input, bytes.length, output, length) == 0) {
        throw const FormatException('无法读取 TXT');
      }
      return String.fromCharCodes(output.asTypedList(length));
    } finally {
      calloc.free(input);
      if (output != nullptr) calloc.free(output);
    }
  }
}
