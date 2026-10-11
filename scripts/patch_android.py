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
    if "usesCleartextTraffic" not in content:
        content = re.sub(
            r"(<application\b[^>]*?)>",
            r'\1 android:usesCleartextTraffic="true">',
            content,
            count=1,
        )

    # 2) 注入 <uses-permission>（在 </manifest> 前）
    if "android.permission.POST_NOTIFICATIONS" not in content:
        block = "\n".join(
            f'    <uses-permission android:name="{p}"/>' for p in PERMISSIONS
        )
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
    write_file_paths()
    print("patched: permissions + usesCleartextTraffic + FileProvider + queries")
