<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="112" alt="MauQuota 图标">
</p>

<h1 align="center">MauQuota</h1>

<p align="center">
  <strong>轻量级原生 macOS 菜单栏 Codex 额度监控</strong><br>
  <sub>A lightweight native macOS menu bar monitor for Codex usage limits</sub>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple&amp;logoColor=white">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&amp;logoColor=white">
  <img alt="Version 1.8.5" src="https://img.shields.io/badge/version-1.8.5-2ea44f">
  <img alt="License Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue">
  <img alt="Build & Release" src="https://github.com/MauriceLiang/MauQuota/actions/workflows/build-release.yml/badge.svg">
</p>

MauQuota 常驻菜单栏，直接显示 Codex 的 **5 小时**与**每周**额度剩余百分比和重置时间。原生 Swift + AppKit 实现：没有 Electron，没有 WebView，没有主窗口，也不占用 Dock。

## 特性

- **原生轻量** —— Swift + AppKit 编译为单一可执行文件，无 Electron 与 WebView 运行时开销。
- **双环额度指示** —— 外环代表每周剩余额度，内环代表 5 小时剩余额度；每个环根据自身剩余比例变色，百分比也可显示对应颜色。圆环显示和数字着色可分别开关。
- **官方登录流程** —— 通过 Codex CLI 的 `app-server` 发起 ChatGPT 浏览器授权，应用不存储密码或令牌。
- **按需刷新** —— 预设间隔与 1–120 分钟自定义刷新，睡眠唤醒后自动更新。
- **隐私优先** —— 只读取额度与账号元数据；诊断信息不包含邮箱、密码或访问令牌。
- **双语界面** —— 跟随系统、简体中文、English。

## 菜单栏一览

菜单栏标题形如 `5h 79% · 7d 45%`：

| 元素 | 含义 |
| --- | --- |
| `5h 79%` | 5 小时窗口剩余 79% |
| `7d 45%` | 每周窗口剩余 45% |
| 外环 | 每周额度剩余比例 |
| 内环 | 5 小时额度剩余比例 |
| 绿色 | 剩余 51–100% |
| 橙色 | 剩余 21–50% |
| 红色 | 剩余 0–20% |

> 文字仅显示 Codex 返回的额度窗口。缺失或无法确认的窗口以灰色轨道表示未知，不会被解释为无限额；剩余为 0% 时显示淡红色轨道。

## 工作原理

MauQuota 不直接调用 OpenAI API，而是以 JSON-RPC 与官方 `codex app-server --stdio` 通信：

- `account/read` 获取登录状态与账号信息；
- `account/rateLimits/read` 获取额度窗口，并按窗口时长区分 5 小时与每周额度；
- `account/login/start` 打开系统浏览器，由 Codex CLI 完成 OAuth 回调。

应用不接触凭据，账号信息仅在内存中用于展示，不做持久化。

## 构建与运行

要求 macOS 13+（Apple Silicon / Intel）与 Xcode 命令行工具：

```bash
xcode-select --install
```

从源码构建并启动：

```bash
git clone https://github.com/MauriceLiang/MauQuota.git && cd MauQuota && swift run -c release MauQuota
```

程序以菜单栏应用方式运行，没有主窗口，也不占用 Dock。图标资源位于 `Resources/`。

仓库的 GitHub Actions 会在 main 与 PR 上运行测试并构建 Apple Silicon / Intel 两种架构的 DMG；推送 `v*` 标签时自动创建 GitHub Release。Release 中的 DMG 为 ad-hoc 签名、未经 Apple 公证，首次运行可能出现 Gatekeeper 提示。

## 使用

1. 安装 Codex CLI：`npm install -g @openai/codex`。
2. 启动 MauQuota，若尚未登录，从菜单栏选择「使用 ChatGPT 登录…」，在系统浏览器完成官方授权。
3. 已登录时会直接请求额度；可随时点击「立即刷新」。
4. 查询异常时，使用菜单栏的「复制诊断信息」。

MauQuota 会尝试沿用 macOS 静态系统代理设置；PAC 与仅写在 `.zshrc` 中的代理可能不会被 Finder 启动的应用继承。

## 测试

```bash
swift test
```

核心逻辑（额度解析、进程通信、偏好设置）均有单元测试覆盖。运行测试需要完整 Xcode（命令行工具不含 XCTest）。

## 版本记录

**v1.8.5**

- 彩色额度数字菜单新增红色数字视觉偏移补偿开关，默认关闭。

**v1.8.0**

- 菜单栏额度数字可显示与对应圆环一致的颜色，并可独立开关。

**v1.7.0**

- 菜单栏双环根据各自的剩余额度显示绿色、橙色或红色，未知和耗尽状态也有区分。

**v1.6.0**

- 正式更名为 **MauQuota**，Bundle ID `dev.mau.mauquota`。
- 首次启动自动迁移旧版 `dev.mau.codexmeter` 的三项设置，不复制任何凭据。
- 修正启动台图标比例，重新生成完整图标集。

## 许可

[Apache License 2.0](LICENSE)。本项目与 OpenAI 无关联。
