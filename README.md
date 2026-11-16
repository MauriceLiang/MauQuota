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
  <img alt="Version 1.8.6 preview" src="https://img.shields.io/badge/version-1.8.6--preview.7-orange">
  <img alt="License Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue">
  <img alt="Build & Release" src="https://github.com/MauriceLiang/MauQuota/actions/workflows/build-release.yml/badge.svg">
</p>

MauQuota 常驻菜单栏，直接显示 Codex 的 **5 小时**与**每周**额度剩余百分比和重置时间。原生 Swift + AppKit 实现：没有 Electron，没有 WebView，没有主窗口，也不占用 Dock。

## 特性

- **原生轻量** —— Swift + AppKit 编译为单一可执行文件，无 Electron 与 WebView 运行时开销。
- **双环额度指示** —— 外环代表每周剩余额度，内环代表 5 小时剩余额度；每个环根据自身剩余比例变色，百分比也可显示对应颜色。圆环显示和数字着色可分别开关。
- **独立运行** —— App 内置官方 Codex App Server 原生运行组件，不要求用户预装 Codex CLI、Node.js 或 npm。
- **官方登录流程** —— 通过内置 Codex App Server 发起 ChatGPT 浏览器授权，应用不请求或读取用户密码。
- **使用限额重置** —— 查看可用重置额度及到期时间，选择具体卡片并二次确认后使用；成功后自动刷新额度。历史页展示 MauQuota 本机发起的重置，并可跳转查看 ChatGPT 官方完整记录。
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

MauQuota 不直接调用 OpenAI API，而是以 JSON-RPC 与随应用打包的官方 `codex-app-server --listen stdio://` 通信。当前预览版内置 Codex App Server 运行组件 `0.169.0`，根据 Mac 芯片架构分别打包。用户无需安装 Codex CLI、Node.js 或 npm。

- `account/read` 获取登录状态与账号信息；
- `account/rateLimits/read` 获取额度窗口及可用重置额度详情；
- `account/rateLimitResetCredit/consume` 按卡片 ID 和幂等键执行用户确认的重置；
- `account/login/start` 打开系统浏览器，由官方 App Server 完成 OAuth 回调。

重置卡历史查询尚未由 App Server 暴露。MauQuota 的历史页只记录通过本应用成功执行的重置；要查看其他设备、自动重置及已收到但未使用的完整记录，可打开 ChatGPT 的 Usage settings。

登录凭据由官方 Codex 运行组件管理，MauQuota 不读取或保存密码、访问令牌。账号元数据和额度仅在内存中用于展示。运行时优先使用 App Bundle 内置版本；若内置文件缺失，则兼容查找系统中已安装的 Codex CLI。

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

1. 下载并启动 MauQuota（无需单独安装 Codex CLI、Node.js 或 npm）。
2. 若尚未登录，从菜单栏选择「使用 ChatGPT 登录…」，在系统浏览器完成官方授权。
3. 授权完成后自动获取额度；可随时点击「立即刷新」。
4. 查询异常时，使用菜单栏的「复制诊断信息」。

MauQuota 会尝试沿用 macOS 静态系统代理设置；PAC 与仅写在 `.zshrc` 中的代理可能不会被 Finder 启动的应用继承。

## 测试

```bash
swift test
```

核心逻辑（额度解析、进程通信、偏好设置）均有单元测试覆盖。运行测试需要完整 Xcode（命令行工具不含 XCTest）。

## 版本记录

**v1.8.6-preview.7**

- 修复重置额度页面纵向布局：可用额度和历史记录均从顶部开始连续排列，不再将多余高度分散到内容项之间。
- 将一次性权益说明放回页面内容流末尾，避免固定在窗口底部造成上下割裂。

**v1.8.6-preview.6**

- 重置额度窗口改为居中限宽布局；页面标题、说明、数量、卡片信息和历史记录统一左对齐。
- 卡片操作按钮保留在行尾，工具栏保持左侧标签切换、右侧刷新；历史页按钮统一左对齐。

**v1.8.6-preview.5**

- 新增 Codex 使用限额重置入口：查看可用重置卡、有效期和说明，选择指定卡片并二次确认。
- 通过官方 App Server 消费重置额度，使用持久化幂等键保护不确定结果的安全重试；成功后刷新额度。
- 新增 MauQuota 本机重置历史，并提供 ChatGPT 官方完整历史入口。

**v1.8.6-preview.4**

- 信息区域改用自定义菜单视图绘制，绕过 AppKit 对禁用菜单项的灰化处理；保持只读且不可点击。

**v1.8.6-preview.3**

- 账号、邮箱、额度和更新时间使用系统标准文字颜色，同时保持真正的只读禁用状态。

**v1.8.6-preview.2**

- 账号、邮箱、额度和更新时间改为正常文字显示，同时保持只读，不响应菜单操作。

**v1.8.6-preview.1**

- 内置官方独立 Codex App Server，不再要求用户安装 Codex CLI、Node.js 或 npm。
- 登录时同步确认系统浏览器是否成功打开；失败时显示明确错误提示。
- 诊断信息增加运行组件路径与来源。

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

[Apache License 2.0](LICENSE)。随应用分发的官方 Codex App Server 运行组件遵循其上游 [Apache License 2.0](https://github.com/openai/codex/blob/main/LICENSE)，详见 `THIRD_PARTY_NOTICES.md`。本项目与 OpenAI 无关联。
