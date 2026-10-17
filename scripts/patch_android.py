#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CI 步骤：flutter create 生成标准脚手架后，把本项目的权限/配置补丁注入
android/app/src/main/AndroidManifest.xml，并生成 file_paths.xml。
这样无需本机安装 Flutter，也能让权限真实生效。
幂等：重复运行不会重复添加。
"""
import os
import re

MANIFEST = "android/app/src/main/AndroidManifest.xml"
RES_XML_DIR = "android/app/src/main/res/xml"

# 需要的全部权限（含普通权限 + 敏感权限）
PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.WRITE_EXTERNAL_STORAGE",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_AUDIO",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
]


def patch_manifest() -> None:
    with open(MANIFEST, "r", encoding="utf-8") as f:
        content = f.read()

    # 1) 给 <application> 加 usesCleartextTraffic（后端是 HTTP 明文）
    #    以及 requestLegacyExternalStorage（gal 插件在 API 29 存相册需要）
    if "usesCleartextTraffic" not in content:
        content = re.sub(
            r"(<application\b[^>]*?)>",
            r'\1 android:usesCleartextTraffic="true">',
            content,
            count=1,
        )
    if "requestLegacyExternalStorage" not in content:
        content = re.sub(
            r"(<application\b[^>]*?)>",
            r'\1 android:requestLegacyExternalStorage="true">',
            content,
            count=1,
        )

    # 2) 注入 <uses-permission>（在 </manifest> 前）
    #    WRITE_EXTERNAL_STORAGE 需带 maxSdkVersion=29（gal 要求，API>29 走 MediaStore 不需要）
    if "android.permission.POST_NOTIFICATIONS" not in content:
        lines = []
        for p in PERMISSIONS:
            if p == "android.permission.WRITE_EXTERNAL_STORAGE":
                lines.append(
                    '    <uses-permission android:name="%s" android:maxSdkVersion="29"/>' % p
                )
            else:
                lines.append('    <uses-permission android:name="%s"/>' % p)
        block = "\n".join(lines)
        content = content.replace("</manifest>", block + "\n</manifest>", 1)

    # 3) 注入 FileProvider（open_filex 调系统播放器必须）
    if "fileprovider" not in content:
        provider = """        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>"""
        content = content.replace("</application>", provider + "\n    </application>", 1)

    # 3.5) 注入前台服务（flutter_foreground_task 常驻监听剪贴板）
    if "flutter_foreground_task" not in content:
        fg = """        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:exported="false"
            android:foregroundServiceType="dataSync" />"""
        content = content.replace("</application>", fg + "\n    </application>", 1)

    # 4) 注入 <queries>（Android 11+ 让系统能找到视频/图片播放器）
    if "<queries>" not in content:
        queries = """    <queries>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:mimeType="video/*" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:mimeType="image/*" />
        </intent>
    </queries>"""
        content = content.replace("</manifest>", queries + "\n</manifest>", 1)

    # 4.5) 注入透明剪贴板代理 Activity（照 CSDN 文章：后台点通知按钮 →
    #      启动透明 Activity 获得焦点 → onWindowFocusChanged 读剪贴板，
    #      合法绕开 Android 10+ 后台读剪贴板限制，用户无感知）
    if "ClipboardProxyActivity" not in content:
        proxy = """        <activity
            android:name=".ClipboardProxyActivity"
            android:theme="@android:style/Theme.Translucent.NoTitleBar"
            android:excludeFromRecents="true"
            android:taskAffinity=""
            android:exported="true" />"""
        content = content.replace("</application>", proxy + "\n    </application>", 1)

    # 4.6) 注入快捷设置磁贴（下拉通知栏点一下 → 读剪贴板 → 弹下载横幅）
    #      需要用户自己在通知栏「编辑」里把它拖出来；BIND_QUICK_SETTINGS_TILE
    #      是系统要求的绑定权限，由系统授予，不需要我们申请。
    if "ClipboardTileService" not in content:
        tile = """        <service
            android:name=".ClipboardTileService"
            android:label="抖音下载"
            android:icon="@mipmap/ic_launcher"
            android:exported="true"
            android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
            <intent-filter>
                <action android:name="android.service.quicksettings.action.QS_TILE" />
            </intent-filter>
        </service>"""
        content = content.replace("</application>", tile + "\n    </application>", 1)

    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(content)


def patch_build_gradle() -> None:
    """Enable core library desugaring.

    flutter_local_notifications (and other modern plugins) use Java 8+ APIs
    that require desugaring to be enabled, otherwise Gradle fails with:
      "Dependency ':flutter_local_notifications' requires core library
       desugaring to be enabled for :app."
    If the dependency is missing you get:
      "coreLibraryDesugaring configuration contains no dependencies."

    Handles BOTH Gradle dialects Flutter may emit:
      - Groovy DSL   -> android/app/build.gradle      (flag: coreLibraryDesugaringEnabled = true)
      - Kotlin DSL   -> android/app/build.gradle.kts   (flag: isCoreLibraryDesugaringEnabled = true)
    The dependency string is identical in both dialects.
    """
    DESUGAR_DEP = 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")'
    configs = {
        "android/app/build.gradle": "coreLibraryDesugaringEnabled = true",
        "android/app/build.gradle.kts": "isCoreLibraryDesugaringEnabled = true",
    }
    patched = []
    for gradle, flag in configs.items():
        if not os.path.exists(gradle):
            continue
        with open(gradle, "r", encoding="utf-8") as f:
            content = f.read()
        modified = False

        # 1) Enable the desugaring flag inside compileOptions (if not already).
        if "coreLibraryDesugaring" not in content:
            content, n = re.subn(
                r"(compileOptions\s*\{)",
                r"\1\n        " + flag,
                content,
                count=1,
            )
            if n:
                modified = True

        # 2) Add the desugar_jdk_libs dependency.
        #    Try to insert into an existing `dependencies {` block; if the
        #    generated template uses an unexpected layout and the regex misses,
        #    fall back to appending a standalone `dependencies { }` block so the
        #    dependency is guaranteed to be present (Gradle allows multiple
        #    dependencies blocks).
        if "coreLibraryDesugaring(" not in content:
            newc, n = re.subn(
                r"(dependencies\s*\{)",
                r"\1\n    " + DESUGAR_DEP,
                content,
                count=1,
            )
            if n == 0:
                if not content.endswith("\n"):
                    content += "\n"
                newc = content + "dependencies {\n    " + DESUGAR_DEP + "\n}\n"
                print("WARN: no 'dependencies {' found in %s; appended one" % gradle)
            content = newc
            modified = True

        if modified:
            with open(gradle, "w", encoding="utf-8") as f:
                f.write(content)
            patched.append(gradle)

    if patched:
        print("patched desugaring into: " + ", ".join(patched))
    else:
        print("WARN: no android/app/build.gradle(.kts) found; desugaring NOT patched")


def write_file_paths() -> None:
    os.makedirs(RES_XML_DIR, exist_ok=True)
    xml = """<?xml version="1.0" encoding="utf-8"?>
<paths>
    <external-path name="external_files" path="." />
    <external-path name="downloads" path="Download" />
    <files-path name="internal_files" path="." />
</paths>
"""
    with open(os.path.join(RES_XML_DIR, "file_paths.xml"), "w", encoding="utf-8") as f:
        f.write(xml)


def patch_min_sdk() -> None:
    """统一 minSdk 到 24（Android 7.0）。

    Flutter 模板默认可能更低，而个别插件（通知/前台服务等）要求更高；
    提前抬到 24 可避免构建期报 "uses-sdk:minSdkVersion ... cannot be smaller"。
    """
    for gradle in ("android/app/build.gradle", "android/app/build.gradle.kts"):
        if not os.path.exists(gradle):
            continue
        with open(gradle, "r", encoding="utf-8") as f:
            content = f.read()

        patched = False
        if "minSdkVersion" in content:
            newc, n = re.subn(
                r"minSdkVersion\s+(\d+)",
                lambda m: "minSdkVersion %d" % max(int(m.group(1)), 24),
                content,
                count=1,
            )
            if n:
                content = newc
                patched = True
                print("patched minSdkVersion to 24 in %s" % gradle)
        elif "minSdk" in content:
            newc, n = re.subn(
                r"minSdk\s*=\s*(\d+)",
                lambda m: "minSdk = %d" % max(int(m.group(1)), 24),
                content,
                count=1,
            )
            if n:
                content = newc
                patched = True
                print("patched minSdk to 24 in %s" % gradle)
        else:
            print("WARN: no minSdk in %s; minSdk NOT raised" % gradle)
            continue

        if patched:
            with open(gradle, "w", encoding="utf-8") as f:
                f.write(content)


# NOTE: __main__ 入口已移到文件末尾（在 patch_kotlin 定义之后）执行，避免 NameError。


# 透明剪贴板代理 Activity 模板（__PKG__ 会被替换为真实包名）
PROXY_KT_TEMPLATE = """package __PKG__

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

// 透明 Activity：把「用户点磁贴 / 通知按钮」转成「前台焦点」，在窗口真正获得
// 焦点后读剪贴板。Android 10+ 只有当前有焦点的应用才能读剪贴板，后台服务里
// 读恒为 null —— 这条系统限制绕不过去，但「用户主动点一下 → 我们立刻变成前台」
// 是系统允许的合法路径。读完 0.2~0.4 秒内 finish，用户几乎看不到界面。
class ClipboardProxyActivity : Activity() {
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.getStringExtra("action") != "read_clipboard") {
            finish()
            return
        }
        // 部分 ROM 的透明 Activity 不回调 onWindowFocusChanged，这里多重兜底
        window.decorView.postDelayed({ tryRead() }, 120)
        window.decorView.postDelayed({ tryRead() }, 350)
        window.decorView.postDelayed({ giveUp() }, 1500)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) tryRead()
    }

    private fun readClipboard(): String? {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.primaryClip?.getItemAt(0)?.text?.toString()
        } catch (e: Exception) {
            null
        }
    }

    private fun tryRead() {
        if (handled) return
        val text = readClipboard()
        if (text.isNullOrBlank()) return
        handled = true
        if (!sendToFlutter(text)) {
            // Flutter 引擎已不在（App 被系统回收）：把 App 拉起来，
            // 它回到前台时会自己再检测一次剪贴板，效果一样。
            try {
                startActivity(Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                })
            } catch (e: Exception) {
                Toast.makeText(this, "打开抖音下载器失败", Toast.LENGTH_SHORT).show()
            }
        }
        finish()
    }

    private fun giveUp() {
        if (handled) return
        handled = true
        Toast.makeText(this, "剪贴板是空的：请先在抖音里「分享 → 复制链接」", Toast.LENGTH_LONG).show()
        finish()
    }

    private fun sendToFlutter(text: String): Boolean {
        val engine = FlutterEngineCache.getInstance().get("main") ?: return false
        return try {
            MethodChannel(engine.dartExecutor.binaryMessenger, "clipboard_proxy")
                .invokeMethod("onClipboard", text)
            true
        } catch (e: Exception) {
            false
        }
    }
}
"""

# 快捷设置磁贴模板：下拉通知栏点一下 → 透明 Activity 获得焦点读剪贴板 → 弹横幅
TILE_KT_TEMPLATE = """package __PKG__

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

// 快捷设置磁贴（下拉通知栏里的图标）：用户点一下 → 启动透明 Activity 读剪贴板
// → 回传 Flutter 弹「立即下载」横幅。不需要任何敏感权限，也不跟抖音抢：
// 用户主动点这一下，就是一次合法、确定能成功的前台读取。
class ClipboardTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        try {
            qsTile?.apply {
                state = Tile.STATE_INACTIVE
                label = "抖音下载"
                updateTile()
            }
        } catch (e: Exception) {
            // 部分 ROM 的 qsTile 可能为空，忽略即可
        }
    }

    @Suppress("DEPRECATION")
    override fun onClick() {
        super.onClick()
        try {
            val intent = Intent(this, ClipboardProxyActivity::class.java).apply {
                putExtra("action", "read_clipboard")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivityAndCollapse(intent)
        } catch (e: Exception) {
            Toast.makeText(this, "启动失败：${e.message}", Toast.LENGTH_SHORT).show()
        }
    }
}
"""

# MainActivity 模板：缓存引擎到 FlutterEngineCache("main")，并注册 native_control
# 通道（收到 startClipboardProxy 即启动透明 Activity）
MAIN_KT_TEMPLATE = """package __PKG__

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 缓存主引擎，供 ClipboardProxyActivity 回传剪贴板文本
        FlutterEngineCache.getInstance().put("main", flutterEngine)
        // 原生通道：前台服务通知按钮点「读取剪贴板」时，由后台 isolate 调此启动透明 Activity
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "native_control")
            .setMethodCallHandler { call, result ->
                if (call.method == "startClipboardProxy") {
                    val intent = android.content.Intent(this, ClipboardProxyActivity::class.java).apply {
                        putExtra("action", "read_clipboard")
                        addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
"""


def patch_kotlin() -> None:
    """注入剪贴板链路需要的原生代码。

    - 重写 MainActivity：缓存引擎到 FlutterEngineCache("main")，并注册
      native_control 通道（收到 startClipboardProxy 即启动透明 Activity）。
    - 写入 ClipboardProxyActivity.kt：透明主题，获得焦点后读剪贴板，
      经 clipboard_proxy 通道发回 Flutter；读不到内容会 Toast 提示。
    - 写入 ClipboardTileService.kt：快捷设置磁贴，点一下就走同一条链路。
    幂等：已存在对应文件则跳过。
    """
    # 1) 提取包名（namespace 优先，fallback applicationId，再 fallback 默认）
    pkg = "com.example.hello_world_app"
    for gradle in ("android/app/build.gradle", "android/app/build.gradle.kts"):
        if not os.path.exists(gradle):
            continue
        with open(gradle, "r", encoding="utf-8") as f:
            g = f.read()
        m = re.search(r'namespace\s+"([^"]+)"', g)
        if not m:
            m = re.search(r'namespace\s*=\s*"([^"]+)"', g)
        if not m:
            m = re.search(r'applicationId\s+"([^"]+)"', g)
        if not m:
            m = re.search(r'applicationId\s*=\s*"([^"]+)"', g)
        if m:
            pkg = m.group(1)
            break

    pkg_dir = os.path.join("android", "app", "src", "main", "kotlin", *pkg.split("."))
    os.makedirs(pkg_dir, exist_ok=True)

    # 2) MainActivity.kt：缓存引擎 + 注册 native_control
    main_kt = os.path.join(pkg_dir, "MainActivity.kt")
    main_content = MAIN_KT_TEMPLATE.replace("__PKG__", pkg)
    if os.path.exists(main_kt):
        with open(main_kt, "r", encoding="utf-8") as f:
            cur = f.read()
        if "FlutterEngineCache" not in cur:
            with open(main_kt, "w", encoding="utf-8") as f:
                f.write(main_content)
            print("patched MainActivity.kt (cached engine + native_control)")
        else:
            print("MainActivity.kt already patched, skip")
    else:
        with open(main_kt, "w", encoding="utf-8") as f:
            f.write(main_content)
        print("wrote MainActivity.kt")

    # 3) ClipboardProxyActivity.kt
    proxy_kt = os.path.join(pkg_dir, "ClipboardProxyActivity.kt")
    if not os.path.exists(proxy_kt):
        with open(proxy_kt, "w", encoding="utf-8") as f:
            f.write(PROXY_KT_TEMPLATE.replace("__PKG__", pkg))
        print("wrote ClipboardProxyActivity.kt")
    else:
        print("ClipboardProxyActivity.kt already exists, skip")

    # 4) ClipboardTileService.kt（快捷设置磁贴：下拉通知栏点一下读剪贴板）
    tile_kt = os.path.join(pkg_dir, "ClipboardTileService.kt")
    if not os.path.exists(tile_kt):
        with open(tile_kt, "w", encoding="utf-8") as f:
            f.write(TILE_KT_TEMPLATE.replace("__PKG__", pkg))
        print("wrote ClipboardTileService.kt")
    else:
        print("ClipboardTileService.kt already exists, skip")


def patch_gradle_properties() -> None:
    """放宽 Kotlin/Java 的 JVM 目标校验，避免「目标版本不一致」直接把构建搞挂。

    踩坑记录（Run #27/#28/#29 连续红的原因）：
      · 之前为迁就 shizuku_api（它把 Kotlin 编译目标设成 17，而同模块 Java 还是 11），
        在根 build.gradle.kts 里用 allprojects{ kotlinOptions{...} } 强改 JVM 目标。
      · Kotlin 2.x 把 kotlinOptions / jvmTarget 标成「错误级」弃用，而且 JavaCompile
        的 sourceCompatibility 要的是 String、不是 JavaVersion —— 于是整个构建在
        「脚本编译」阶段就失败，连 APK 都出不来。
      · shizuku_api 已随 B站功能一起移除，这个补丁本来就不需要了。
    现在只把 KGP 的这条校验降级为 warning：万一以后某个插件又不一致，
    构建会给出警告而不是直接失败；JVM 目标本身交给 Flutter 模板保持一致。
    """
    path = "android/gradle.properties"
    key = "kotlin.jvm.target.validation.mode"
    if not os.path.exists(path):
        print("WARN: %s not found; JVM target validation NOT patched" % path)
        return
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if key in content:
        print("%s already has %s, skip" % (path, key))
        return
    if not content.endswith("\n"):
        content += "\n"
    content += ("# [patch] Java/Kotlin 的 JVM 目标不一致时只警告、不中断构建\n"
                "%s=warning\n" % key)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print("patched %s: %s=warning" % (path, key))


if __name__ == "__main__":
    patch_manifest()
    patch_build_gradle()
    patch_min_sdk()
    write_file_paths()
    patch_kotlin()
    patch_gradle_properties()
    print("patched: permissions + usesCleartextTraffic + FileProvider + queries + "
          "coreLibraryDesugaring + minSdk24 + clipboard proxy activity + QS tile + "
          "gradle.properties(JVM validation -> warning)")
