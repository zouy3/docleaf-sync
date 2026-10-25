# 已发布：DocLeaf Sync 同步试用版

下载：https://github.com/zouy3/docleaf-sync/releases/tag/sync-preview-2026-10-25

本次是 Pre-release，不是双端真机验收完成的正式版。旧仓库和旧 Release 未改动。

附件包含 Windows x64、macOS Apple Silicon、macOS Intel 网页包，以及 Android ARM64 / ARMv7 已签名安装包，另附两份 SHA-256 清单。

## 验证

- GitHub Actions 构建和发布全部成功：https://github.com/zouy3/docleaf-sync/actions/runs/40208624726
- 网页生产构建与 9 项测试通过。移动到独立目录后的生产服务启动，返回 HTTP 200，包含账号同步入口。
- 下载实际 Release ZIP 复核了必需文件、核心源代码与许可证、生产网页、启动器和二进制架构；Windows 是 PE x64，两个 Mac 分别为 arm64 与 x86_64。
- 校正了 Mac ZIP 的中文文件名 UTF-8 标志，验证重打包前后所有文件内容逐字节一致，且启动器和核心的执行权限保留。未来工作流使用标准 UTF-8 ZIP 生成器。
- Android 远端附件 digest 与此前本地已验签 APK 完全一致。没有更换证书或重新签名。
- 原开发阶段的检查与未验收项目见 `VERIFICATION.md`。本轮没有重新进行安卓全量测试或真机续读验收。
- Windows 静态资源后续修复已发布，详见 `WINDOWS-STATIC-FIX.md`。新版在真正的 Windows 环境中通过 12 项测试，且对实际 ZIP 解压后启动的 CSS / JavaScript 请求再次验证通过。

最终网页 ZIP SHA-256：

```text
c34fe007da8d0d9ecaeb5d82f5af66f79b6226091a4b0024003c8a4b520f59de  DocLeaf-Sync-Windows-x64.zip
08c70dfd82150276d2c6f006f94d3f04b5525f469cd2ec1e6892ef0cbc2e51fc  DocLeaf-Sync-macOS-Apple-Silicon.zip
baf293921f13caff7b7ce30aec404f7309bd8544e526bf1deabc8707c86d436c  DocLeaf-Sync-macOS-Intel.zip
```

网页包仍需 Node.js 22.13+ 以及首次依赖下载，但不需要 Rust、Flutter 或 Visual Studio。先关闭旧服务，再启动新包；不要把 GitHub 自动生成的 Source code ZIP 当成运行包。
