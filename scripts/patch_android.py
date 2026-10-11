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


if __name__ == "__main__":
    patch_manifest()
    patch_build_gradle()
    write_file_paths()
    print("patched: permissions + usesCleartextTraffic + FileProvider + queries + coreLibraryDesugaring")
