import 'package:flutter/services.dart';

enum ShareLaunchOutcome {
  /// 选择器已弹出。
  launched,

  /// 设备上没有能接住的分享目标（或宿主没注入桥）。
  unavailable,
}

/// 极简的系统分享桥。避免为一个面板引入第三方插件：官方本来就是
/// `Intent.ACTION_SEND`，这里交给宿主注入的实现（Android 侧用
/// `Intent.createChooser`）。
class SharePlusLite {
  const SharePlusLite._();

  /// 宿主注入：返回 **false 表示没能调起**（不是「已分享」）。
  static Future<bool> Function({required String title, required String text})?
  handler = ({required String title, required String text}) async =>
      await const MethodChannel(
        'fqapp/share',
      ).invokeMethod<bool>('shareText', {'title': title, 'text': text}) ??
      false;

  static Future<ShareLaunchOutcome> share({
    required String title,
    required String text,
  }) async {
    final h = handler;
    if (h == null) return ShareLaunchOutcome.unavailable;
    try {
      final launched = await h(title: title, text: text);
      return launched
          ? ShareLaunchOutcome.launched
          : ShareLaunchOutcome.unavailable;
    } catch (_) {
      return ShareLaunchOutcome.unavailable;
    }
  }
}
