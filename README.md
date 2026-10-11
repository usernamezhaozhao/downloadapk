# Hello World Flutter App

一个最基础的 Flutter 项目：打开 APK 后屏幕中央显示 “Hello World”。

## 仓库里有什么

本仓库**只放纯文本源码**，不在本地编译、不提交任何 Android/iOS 原生文件：

- `lib/main.dart` — 应用入口，展示 Hello World
- `test/widget_test.dart` — 验证屏幕上出现 Hello World
- `pubspec.yaml` — 依赖与 SDK 约束
- `.github/workflows/build-apk.yml` — GitHub Action（负责全部脚手架生成、测试、打包）
- `.gitignore`

> 所有「重活」（生成 Flutter 脚手架、跑测试、打 APK）都在 GitHub Action 里完成。
> 你的电脑不需要安装 Flutter 或 Android SDK。

## 怎么拿到 APK

1. 把这些文件 push 到 GitHub 的 `main` 分支（或到 Actions 页点 “Run workflow” 手动触发）。
2. 进入仓库的 **Actions** 标签页，等 `Build Android APK` 任务变绿。
3. 在任务详情页底部的 **Artifacts** 里下载 `hello-world-apk`（`app-debug.apk`）。
4. 把 APK 传到手机（或拖进模拟器），允许「未知来源」安装后即可打开，看到 Hello World。

## 说明

- 当前打的是 **debug APK**，无需签名即可安装测试。后续要发布时再改成 `--release` 并配置签名即可。
- CI 中通过 `android-actions/setup-android` 安装 Android SDK 并接受许可证，这是 `flutter build apk` 在 GitHub runner 上能跑起来的必要条件。
