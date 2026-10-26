# 安卓应用内更新

从 1.0.133 (138) 起提供“关于 → 检查更新”，并在“我的”顶部显示可点击的登录账号卡片。启动时每天最多检查一次，只提示、不自动下载、不打断阅读。默认包含试用版，可切换到仅正式版；该选择独立保存，不迁移或清除旧设置、书架与登录数据。

用户点击后下载 APK，支持进度、取消、失败重试和服务器支持时的断点续传。下载完成校验 SHA-256，再由 Android 原生层检查包名、递增 versionCode、与当前安装应用一致的签名证书，最后打开系统安装确认界面。安装授权由用户自己在系统设置中允许，不静默安装。

## 后续发布流程

1. 同步递增 `android-app/pubspec.yaml` 与 `lib/services/app_version.dart` 的基础版本，About 页自动使用同一常量，测试会校验一致性。保持 `com.fqapp.fqapp` 和原有签名证书不变。
2. 生成两个已签名 APK，执行现有 APK 验签、ABI 与对齐检查。命名为 `DocLeaf-Sync-版本号-arm64-v8a.apk`、`DocLeaf-Sync-版本号-armeabi-v7a.apk`，放进独立输出目录。
3. 设置 Android SDK 的 `ANDROID_HOME`，在仓库根目录执行 `node scripts/create-android-update-manifest.mjs 输出目录`，会使用 build-tools 36.0.0 的 aapt 读取每个 APK 的真实安装版本，再生成 `android-update.json`。Flutter 分架构 APK 的安装 versionCode 不同于 pubspec 基础版本：例如基础 138 对应 ARM64 2138、ARMv7 1138；不能把基础号用于原生安装核对。若清单已存在则拒绝覆盖，防止混入旧文件。
4. 新建对应版本的 Release（例如 `android-v1.0.133`），上传两个 APK 并确认上传成功后，**最后上传 `android-update.json`**。不要只覆盖旧 APK 或只改 Release 标题。
5. 正式版请取消 Pre-release；试用版保留 Pre-release。应用会读取最近发布列表，过滤草稿和当前渠道，并按清单的 Android versionCode 选择更高版本；不依赖忽略试用版的 `/latest` 接口，网页版更新不会冒充 Android 更新。

清单只包含公开的包名、版本、ABI、文件名、大小和 SHA-256，不含私钥、账号或 GitHub 令牌。只接受本仓库的 HTTPS Release 附件。清单不是安装授权，系统安装器仍要求用户确认，并验证 APK。

## 数据兼容性边界

更新功能只新增 `docleaf_update_*` 偏好键和应用缓存目录 `docleaf-updates/`，不改变已有阅读、书架、主题和账号安全存储键。升级必须覆盖安装；不要卸载或清空应用数据。系统清理、用户主动退出登录、服务端会话撤销等不属于更新能够保证保留的情形。

没有更新功能的旧版仍需手动覆盖安装一次此版本。此后发布带清单的新版，即可在应用内下载更新。首次上线没有比当前版本更高的真实 Release 时，页面显示“当前渠道暂无更高版本”是正常情况。
