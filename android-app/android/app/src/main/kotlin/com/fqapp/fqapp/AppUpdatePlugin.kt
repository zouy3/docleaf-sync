package com.fqapp.fqapp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Only APKs in our private update cache, same package and same signing identity. */
class AppUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "docleaf/update")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null); context = null; io.shutdown()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
    @Suppress("DEPRECATION")
    private fun info(ctx: Context): PackageInfo = ctx.packageManager.getPackageInfo(ctx.packageName, signingFlags())
    private fun signingFlags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature -> MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) } }?.toSet() ?: emptySet()
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("unavailable", "更新通道不可用", null)
        when (call.method) {
            "info" -> {
                val installed = info(ctx)
                result.success(mapOf("packageName" to ctx.packageName, "versionCode" to code(installed), "versionName" to (installed.versionName ?: ""), "abis" to Build.SUPPORTED_ABIS.toList()))
            }
            "permission" -> {
                val host = activity ?: return result.error("no_activity", "请返回应用后操作", null)
                try {
                    if (Build.VERSION.SDK_INT >= 26) host.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}")))
                    result.success(null)
                } catch (_: Exception) { result.error("permission_settings", "无法打开安装授权设置", null) }
            }
            "install" -> {
                val path = call.argument<String>("path") ?: return result.error("bad_file", "缺少安装文件", null)
                val expected = call.argument<Number>("versionCode")?.toLong() ?: return result.error("bad_version", "缺少版本号", null)
                io.execute {
                    val error = try { validate(ctx, File(path), expected); null } catch (e: Exception) { e.message ?: "更新包验证失败" }
                    main.post {
                        if (error != null) { result.error("invalid_update", error, null); return@post }
                        val host = activity ?: run { result.error("no_activity", "请返回应用后操作", null); return@post }
                        if (Build.VERSION.SDK_INT >= 26 && !ctx.packageManager.canRequestPackageInstalls()) {
                            result.success("permission_required"); return@post
                        }
                        try {
                            val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.updates", File(path))
                            host.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success("started")
                        } catch (_: Exception) { result.error("installer_unavailable", "无法打开系统安装界面", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }
    @Suppress("DEPRECATION")
    private fun validate(ctx: Context, raw: File, expected: Long) {
        val file = raw.canonicalFile
        require(file.parentFile == File(ctx.cacheDir, "docleaf-updates").canonicalFile && file.isFile && file.name.endsWith(".apk")) { "更新文件不在专用缓存目录" }
        val incoming = ctx.packageManager.getPackageArchiveInfo(file.path, signingFlags()) ?: error("无法读取 APK，请重新下载")
        val installed = info(ctx)
        UpdateIdentityPolicy.verify(ctx.packageName, incoming.packageName, code(installed), code(incoming), expected,
            certificates(installed), certificates(incoming))
    }
}
