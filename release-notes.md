网页与安卓的独立同步试用版，原 docleaf-reader 不变。

## 网页版下载

- Windows：`DocLeaf-Sync-Windows-x64.zip`
- Mac M 系列：`DocLeaf-Sync-macOS-Apple-Silicon.zip`
- Mac Intel：`DocLeaf-Sync-macOS-Intel.zip`

完整解压后运行包内启动器。已附带番茄书源，不需要安装 Rust 或 Visual Studio。仍需 Node.js 22.13+，首次安装网页依赖需要联网；Windows 启动器可通过 winget 安装 Node.js。

先关闭旧版服务再启动新包，浏览器访问 `http://localhost:3000/`。请不要用旧仓库的包测试新同步功能。不要下载 GitHub 自动生成的 Source code ZIP 来代替上述运行包。

## 安卓版

安卓已签名的 ARM64 / ARMv7 试用包将附在同一 Release。使用此前本地试用版相同证书，不是原作者的正式签名；无法覆盖安装时不要卸载旧版丢失数据，请先备份并反馈。

## 同步与验证

两端使用股票工具的同一账号。在账号同步面板合并本机书架，打开同一本番茄小说继续阅读。仅同步书籍信息、章节/段落/文字偏移和短定位片段，不上传整章、评论或本地导入文件。

离线待同步队列、账号隔离和冲突保护已有自动化测试；网页登录用户已反馈“同步完成”。真实手机与网页的续读位置、弱网和后台恢复仍待验收，因此标记为 Pre-release。

若使用自己的 Supabase 项目，需要先运行仓库内 `sync/schema.sql`。不需要改动原股票表。详情及测试记录见 README 和 `sync/VERIFICATION.md`。
