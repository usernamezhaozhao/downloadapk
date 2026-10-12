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
    # Android 11+ 访问 /Android/data/tv.danmaku.bili（B站缓存目录）需要
    # 「所有文件访问」特殊权限（用户在系统设置手动授予）
    "android.permission.MANAGE_EXTERNAL_STORAGE",
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

    # 3.6) 注入 Shizuku provider（shizuku_api 包 bind Shizuku 服务必需）
    if "rikka.shizuku.ShizukuProvider" not in content:
        shizuku = """        <provider
            android:name="rikka.shizuku.ShizukuProvider"
            android:authorities="${applicationId}.shizuku"
            android:multiprocess="false"
            android:enabled="true"
            android:exported="true"
            android:permission="android.permission.INTERACT_ACROSS_USERS_FULL" />"""
        content = content.replace("</application>", shizuku + "\n    </application>", 1)

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
    """shizuku_api 要求 minSdk >= 24，flutter create 默认可能更低，提到 24。"""
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
            print("WARN: no minSdk in %s; shizuku_api may fail to build" % gradle)
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
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

// 照 CSDN 文章：用透明 Activity 把「后台点击」转成「前台焦点」，
// 在 onWindowFocusChanged(true) 窗口真正获得焦点时读剪贴板（后台读会抛 SecurityException）。
// 读完即 finish，且不带主 task 焦点，用户无感知。
class ClipboardProxyActivity : Activity() {
    private var pending = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pending = intent?.getStringExtra("action") == "read_clipboard"
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && pending) {
            pending = false
            val text = readClipboard()
            if (!text.isNullOrBlank()) {
                sendToFlutter(text)
            }
            finish()
        }
    }

    private fun readClipboard(): String? {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.primaryClip?.getItemAt(0)?.text?.toString()
        } catch (e: Exception) {
            null
        }
    }

    private fun sendToFlutter(text: String) {
        val engine = FlutterEngineCache.getInstance().get("main") ?: return
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, "clipboard_proxy")
                .invokeMethod("onClipboard", text)
        } catch (e: Exception) {
            // ignore
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
    """注入透明剪贴板代理 Activity 与原生通道（照 CSDN 文章架构）。

    - 重写 MainActivity 缓存引擎到 FlutterEngineCache("main")，并注册
      native_control 通道（收到 startClipboardProxy 即启动透明 Activity）。
    - 写入 ClipboardProxyActivity.kt（透明主题，onWindowFocusChanged 读剪贴板，
      经 clipboard_proxy 通道发回 Flutter）。
    幂等：已存在对应内容则跳过。
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


def patch_root_gradle() -> None:
    """统一所有 Android 子模块的 JVM 目标为 17，消除
    "Inconsistent JVM Target Compatibility" 编译失败。

    shizuku_api 插件把 Kotlin 编译目标设为 17，但同模块的 Java 编译目标
    默认仍是 11，AGP 会因此报错：
        compileDebugJavaWithJavac (11) 和 compileDebugKotlin (17) 不一致
    在根 build.gradle.kts 里把所有 android 子模块(含插件)的
    compileOptions 与 kotlinOptions 都拉到 17，从根本上保证一致。
    CI 的 setup-java 已使用 JDK 17，故 17 是安全目标。
    """
    gradle = "android/build.gradle.kts"
    marker = "// [patch] consistent JVM target 17 for all android subprojects"
    if not os.path.exists(gradle):
        print("WARN: %s not found; JVM target NOT patched" % gradle)
        return
    with open(gradle, "r", encoding="utf-8") as f:
        content = f.read()
    if marker in content:
        print("root build.gradle.kts already patched for JVM target, skip")
        return

    block = '''

// [patch] consistent JVM target 17 for all android subprojects
// 统一所有 Android 子模块的 JVM 目标为 17，消除
// "Inconsistent JVM Target Compatibility"（shizuku_api 的 Kotlin=17 / Java=11）。
// CI 使用 JDK 17。
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library") || plugins.hasPlugin("com.android.application")) {
            android {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
                kotlinOptions {
                    jvmTarget = "17"
                }
            }
        }
    }
}
'''
    content = content.rstrip() + block
    with open(gradle, "w", encoding="utf-8") as f:
        f.write(content)
    print("patched root build.gradle.kts: forced JVM target 17 for all android subprojects")


if __name__ == "__main__":
    patch_manifest()
    patch_build_gradle()
    patch_min_sdk()
    write_file_paths()
    patch_kotlin()
    patch_root_gradle()
    print("patched: permissions + usesCleartextTraffic + FileProvider + queries + coreLibraryDesugaring + shizuku provider + minSdk24 + clipboard proxy activity + JVM target 17")
