# 小说独立版 1.0.131

保留小说推荐、搜索、排行榜、详情/目录/书评、阅读器、本地 TXT/EPUB、离线缓存、书架、历史、账号只读导入和备份。
左右方向键、PageUp/PageDown 可翻页；Android 处理 keyboard、keyboardHidden、navigation、touchscreen 配置变化，避免连接键盘时重建 Activity。

删除短剧、漫剧、漫画、在线听书和系统朗读页面及其控制器，删除 Android ExoPlayer/Media3、CENC 原生解密库、悬浮播放与音频前台服务；删除 Windows media_kit/libmpv/SMTC、Flutter TTS/Lottie 依赖及短剧图标、动画和 Web UI。
Rust 删除 audio/video/manga/wkcontent 和相关剧评、音色、视频推荐接口，正文使用的 AES/DH/CM、设备池、签名保留。
旧版非小说数据的格式兼容代码保留，升级不主动擦除旧书架、历史和备份。
首页、统计和书架的本地 TXT/EPUB 打开入口共用本地章节读取，避免继续阅读时误请求在线目录。

构建：Flutter 3.44.6、Dart 3.12.2、JDK 17、Android SDK 36、NDK 28.2.13676358、Rust stable、FRB 2.13.0。

```sh
flutter pub get
bash scripts/build_rust_backend.sh --skip-codegen
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
```

FRB 接口未改变，绑定不需重新生成。Android 只需 libfqapi_core.so，已不再构建 native/ 的短剧 C 库。
使用 scripts/verify_android_apk.py 检查两种 ABI、签名、版本、16 KiB 对齐和已移除的媒体资源。
