# DocLeaf Sync

Word 风格的网页阅读器 + Android 纯文字小说客户端，共用账号同步番茄书架和阅读位置。本仓库是独立同步版，原 `zouy3/docleaf-reader` 不变。

## 当前状态

同步客户端已实现，仍属试用版。离线队列、账号隔离和进度冲突有自动化测试；真实账号的网页 ↔ Android 续读、真机后台恢复尚待验收。不要把构建成功当作双端同步已验收，也不要从旧仓库下载后以为已包含同步功能。

## 预编译运行包

在本仓库 [Releases](https://github.com/zouy3/docleaf-sync/releases) 下载对应文件；网页包由 [发布工作流](https://github.com/zouy3/docleaf-sync/actions/workflows/release-preview.yml) 构建，构建完成后才会出现附件。

- Windows：`DocLeaf-Sync-Windows-x64.zip`
- Mac M 系列：`DocLeaf-Sync-macOS-Apple-Silicon.zip`
- Mac Intel：`DocLeaf-Sync-macOS-Intel.zip`
- 安卓：[1.0.133 应用内更新试用版](https://github.com/zouy3/docleaf-sync/releases/tag/android-v1.0.133)，选择 `arm64-v8a.apk`（多数手机）或 `armeabi-v7a.apk`（32 位）。更新入口在“关于 → 检查更新”，账号入口在“我的”顶部。旧版需手动覆盖安装本版一次，不要卸载清数据。

网页包已带编译好的书源及网页构建产物，无需 Rust、Flutter 或 C++ 构建工具，仍需 Node.js 22.13+ 和首次依赖下载。完整解压后运行启动器；先关闭旧版服务，防止仍打开旧的 localhost:3000 页面。不要把 GitHub 自动生成的 Source code ZIP 当成运行包。

## 同步哪些内容

- 番茄书籍的书号、书名、作者、封面地址。
- 阅读位置：章节 ID、段落 ID、正文文字偏移和短定位片段（最多 32 个 UTF-16 单元）。不使用整本百分比作为跨端定位。
- 不上传整章正文、评论、本地导入文件或阅读器字体设置。
- 离线仍可阅读本机缓存；联网后重试待同步记录。两端同时阅读时不直接覆盖，界面会要求选择本地或云端位置。
- 云端出现更新时，选择“接着读”才跳转，不在阅读中自动抢位置。

## 网页端运行

源码需要 Node.js **22.13+**；番茄服务还需要 Rust。Windows 从源码编译 Rust 时需要 Visual Studio C++ Build Tools（体积较大），macOS 需要命令行开发工具。只运行网页 UI 可先不安装 Rust，但无法在线获取番茄内容。

在项目目录执行：

```sh
npm ci
npm run dev
```

访问 `http://localhost:3000/`。番茄服务需另开终端，在同一目录执行：

```sh
cargo run --manifest-path integrations/fqapp/rust/Cargo.toml --bin docleaf_bridge
```

也可使用已有启动器：macOS 在终端运行 `bash 一键启动.command`；Windows 运行 `一键启动-Windows.bat`。Windows 启动器在缺少依赖时可能通过 winget 安装 Node、Rust 和 C++ 构建工具，请阅读提示。当前不是免安装的可执行文件包。

建议始终使用同一地址 `localhost`。`127.0.0.1` 是另一个浏览器存储来源，书架、登录和本机缓存不会自动共享。

## Android

源码位于 `android-app/`，基于 fqapp 的纯文字小说版，不恢复视频、漫画或独立听书模块。同步入口在“我的”页面右上角的云同步按钮。

需要 Flutter 3.44.6 / Dart 3.12.2、JDK 17、Android SDK 36、NDK 28.2.13676358、Rust 和 PowerShell。先按 `android-app/DEVELOPMENT.md` 配置环境并构建原生核心，然后运行（第一条在仓库根目录执行）：

```sh
node scripts/restore-assets.mjs
cd android-app
flutter pub get
pwsh -File scripts/build_rust_backend.ps1
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
```

图片/字体二进制资源为适配 GitHub MCP 的文本上传，存储于 `sync/binary-assets.json` 及其分片，还原时会校验 SHA-256。网页的 `npm ci` 自动还原；只构建 Android 时需手动执行上述第一条命令，不要省略。

发布签名需自行配置 `android/keystore.properties` 或对应环境变量，不能提交密钥；没有签名配置会得到未签名 APK，不能直接安装。测试包若与旧包签名不同无法覆盖安装，不要为此卸载旧应用丢失书架。详细规则见 `android-app/AGENTS.md`。

## 首次配置云端（只需管理员做一次）

1. 在现有 Supabase 项目的 SQL Editor 运行 `sync/schema.sql`。脚本仅新增 `docleaf_books` 表、自己的 RLS 策略和 `docleaf_save` 函数，不修改股票表或用户账号。
2. 两端使用与股票工具相同的用户名和密码登录。用户名对应 `用户名@users.quiet-notes.invalid`，允许 3–32 位字母、数字、下划线和短横线。
3. 若允许客户端注册，Supabase 的邮箱确认设置必须与现有用户名账号方案兼容；无需创建新的虚假邮箱账号来迁移已有用户。
4. 网页点“账号同步”，Android 点云同步入口，登录后选择“合并本机书架”。在另一端点击云端书籍继续阅读。

客户端只包含项目 URL 和可公开的 publishable key，不含数据库管理密钥。数据库按当前用户隔离读取；写入只允许带用户 JWT 的同步函数，以版本号检查防止旧设备覆盖。首次登录不会把其他账号的本地待同步队列传入当前账号。

网页登录状态存于当前浏览器本地存储，Android 登录凭证存于系统安全存储。退出登录不会删除本机书籍；共享电脑使用完请退出登录。不要向他人发送密码或服务端密钥。

如遇“云端尚未初始化”，检查脚本执行的是否是客户端配置的同一项目；网络或 HTTPS 证书失败不会被当成同步成功，也不会关闭证书校验。

## 验证

```sh
npm test
cd android-app
flutter analyze --no-pub
flutter test --no-pub test/cloud_sync_test.dart test/cloud_position_test.dart
```

## 来源与许可证

番茄核心和 Android 客户端源自 [ch6vip/fqapp](https://github.com/ch6vip/fqapp)，修改版保留 GPL-3.0 许可证（见 `android-app/LICENSE` 和 `integrations/fqapp/LICENSE`）。本仓库不提供小说内容；请遵守内容版权与平台规则。同步账号是自建 Supabase 账号，不是番茄账号，不向番茄回写阅读进度。
