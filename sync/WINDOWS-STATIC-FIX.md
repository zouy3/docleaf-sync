# Windows 生产模式样式与脚本修复

已替换原试用版 Release 的 Windows ZIP，Mac 和安卓附件 digest 保持不变。

- Release：https://github.com/zouy3/docleaf-sync/releases/tag/sync-preview-2026-10-25
- 修复代码：252aff40e03477b025800dacdf550309d26c44a1
- Windows 构建与发布验收：https://github.com/zouy3/docleaf-sync/actions/runs/40219886644
- Windows ZIP SHA-256：`c34fe007da8d0d9ecaeb5d82f5af66f79b6226091a4b0024003c8a4b520f59de`

## 原因

vinext 0.0.50 的生产静态缓存以操作系统相对路径建立键。在 Windows 上键中包含反斜杠，而 HTTP 请求使用正斜杠，所以页面本身返回 200，CSS 和 JavaScript 却无法命中缓存。此前仅检查构建结果和 HTML 200，不足以证明页面在 Windows 上可用。

## 修复

`npm start` 使用应用自己的启动入口，在框架建立缓存后统一 URL 键，并过滤私有 `.vite` 清单。保留文件磁盘路径和响应处理，不修改共享 node_modules、不升级依赖，也不操作用户书架或数据库。未来升级框架时须复核适配层。

## 验证

- 本地生产构建、12 项测试通过。
- GitHub Windows runner：12 项测试通过。
- Windows 上对实际生成的 ZIP 解压，再用包内启动入口运行：HTML、CSS、5 个 JavaScript 资源均为 200，CSS / JS Content-Type 正确，私有清单未暴露。
- 下载已替换的 Release ZIP 复核其 SHA-256、包内启动配置和适配脚本，均与预期一致。
- 未声称已在用户电脑上进行视觉验收；若用户仍看到旧页面，先确认旧服务已关闭，并强制刷新。

## 用户操作

关闭旧 DocLeaf 服务窗口，重新下载 Windows ZIP，完整解压到新目录，双击 `一键启动-Windows.bat`；浏览器使用相同的 `http://localhost:3000/`，必要时按 Ctrl+F5。无需清除浏览器数据，书架仍保存在原浏览器来源下。
