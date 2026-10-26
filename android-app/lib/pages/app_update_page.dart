import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/app_update.dart';

class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, this.service});
  final AppUpdateService? service;
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final AppUpdateService update =
      widget.service ?? AppUpdateService.instance;
  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      await update.initialize();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新初始化失败：$e')));
      }
    }
  }

  Future<void> _permission() async {
    try {
      await update.openInstallPermission();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('检查更新')),
    body: ListenableBuilder(
      listenable: update,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '当前版本：${update.device?.versionName ?? '读取中'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          const Text('启动时每天最多自动检查一次，只提示新版。点击下载后才会下载，安装需系统确认。'),
          const SizedBox(height: 16),
          DropdownButtonFormField<UpdateChannel>(
            key: ValueKey(update.channel),
            initialValue: update.channel,
            decoration: const InputDecoration(labelText: '更新渠道'),
            items: const [
              DropdownMenuItem(value: UpdateChannel.stable, child: Text('正式版')),
              DropdownMenuItem(
                value: UpdateChannel.preview,
                child: Text('试用版（含正式版）'),
              ),
            ],
            onChanged: update.busy
                ? null
                : (value) {
                    if (value != null) unawaited(update.setChannel(value));
                  },
          ),
          const SizedBox(height: 16),
          Text(update.status),
          if (update.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                update.error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: update.busy || !update.supported
                ? null
                : () => unawaited(update.check()),
            child: Text(update.checking ? '检查中…' : '检查更新'),
          ),
          if (update.candidate case final AppUpdate candidate) ...[
            const Divider(height: 32),
            Text(
              '新版本 ${candidate.version}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${candidate.abi} · ${(candidate.size / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
            const SizedBox(height: 12),
            Text(candidate.notes.isEmpty ? '暂无更新说明' : candidate.notes),
            if (update.downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: update.total > 0 ? update.received / update.total : null,
              ),
              Text(
                '${(update.received / 1024 / 1024).toStringAsFixed(1)} / ${(update.total / 1024 / 1024).toStringAsFixed(1)} MB',
              ),
              TextButton(
                onPressed: update.cancelDownload,
                child: const Text('取消下载'),
              ),
            ] else if (update.apk == null)
              FilledButton(
                onPressed: update.busy
                    ? null
                    : () => unawaited(update.download()),
                child: const Text('下载更新／继续下载'),
              )
            else ...[
              FilledButton(
                onPressed: update.busy
                    ? null
                    : () => unawaited(update.install()),
                child: const Text('安装更新'),
              ),
              TextButton(
                onPressed: update.busy ? null : _permission,
                child: const Text('允许本应用安装更新'),
              ),
              const Text('覆盖安装会保留本机数据。若提示签名不一致，请勿卸载旧版。'),
            ],
          ],
          const SizedBox(height: 16),
          TextButton(
            onPressed: () async {
              final uri =
                  update.candidate?.releaseUrl ??
                  Uri.parse('https://github.com/zouy3/docleaf-sync/releases');
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
                  context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，请稍后重试')));
              }
            },
            child: const Text('在浏览器查看发布页'),
          ),
          const Text('检查或下载失败不会影响阅读。GitHub 无法访问时，请检查网络后重试。'),
        ],
      ),
    ),
  );
}

class AppUpdateNotice extends StatelessWidget {
  const AppUpdateNotice({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppUpdateService.instance,
    builder: (context, _) {
      final update = AppUpdateService.instance;
      if (update.candidate == null) return const SizedBox.shrink();
      return Card(
        child: ListTile(
          leading: const Icon(Icons.system_update),
          title: Text('发现新版本 ${update.candidate!.version}'),
          subtitle: const Text('点此查看更新说明并下载'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const AppUpdatePage()),
          ),
        ),
      );
    },
  );
}
