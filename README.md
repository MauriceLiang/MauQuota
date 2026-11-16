<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="112" alt="MauQuota icon">
</p>

<h1 align="center">MauQuota</h1>

<p align="center">
  <strong>轻量级原生 macOS 菜单栏 Codex 额度监控</strong><br>
  <sub>A lightweight native macOS menu bar monitor for Codex usage limits</sub>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple&amp;logoColor=white">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&amp;logoColor=white">
  <img alt="Version 2.0.0" src="https://img.shields.io/badge/version-2.0.0--preview.1-orange">
  <img alt="License Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue">
  <img alt="Build & Release" src="https://github.com/MauriceLiang/MauQuota/actions/workflows/build-release.yml/badge.svg">
</p>

MauQuota 常驻菜单栏，直接显示 Codex 的 **5 小时**与**每周**额度剩余百分比和重置时间。原生 Swift + AppKit 实现：没有 Electron，没有 WebView，没有常驻后台运行组件，也不占用 Dock。

## 特性

- **原生轻量** —— Swift + AppKit 编译为单一可执行文件，不依赖 Codex CLI、Codex App Server、Node.js 或 npm。
- **原生 ChatGPT 登录** —— 浏览器 OAuth Authorization Code + PKCE，使用本地回调接收授权结果，不要求用户输入账号密码。
- **Keychain 凭据管理** —— Access Token、Refresh Token 和账号标识保存在 macOS Keychain，不读取或修改 <code>~/.codex/auth.json</code>。
- **直接额度查询** —— 使用 ChatGPT 后端接口获取 5 小时和每周额度，不启动外部进程。
- **自动刷新 Token** —— Access Token 即将过期或服务端返回 401 时，使用 Refresh Token 更新凭据并重试一次。
- **双环额度指示** —— 外环代表每周剩余额度，内环代表 5 小时剩余额度；每个环根据自身剩余比例变色，百分比也可显示对应颜色。圆环显示和数字着色可分别开关。
- **使用限额重置** —— 查看可用重置额度及到期时间，选择具体卡片并二次确认后使用；成功后自动刷新额度。历史页展示 MauQuota 本机发起的重置，并可跳转查看 ChatGPT 官方完整记录。
- **按需刷新** —— 预设间隔与 1–120 分钟自定义刷新，睡眠唤醒后自动更新。
- **隐私优先** —— 诊断信息不包含邮箱、密码、Access Token 或 Refresh Token。
- **双语界面** —— 跟随系统、简体中文、English。

## 菜单栏一览

菜单栏标题形如 <code>5h 79% · 7d 45%</code>：

| 元素 | 含义 |
| --- | --- |
| <code>5h 79%</code> | 5 小时窗口剩余 79% |
| <code>7d 45%</code> | 每周窗口剩余 45% |
| 外环 | 每周额度剩余比例 |
| 内环 | 5 小时额度剩余比例 |
| 绿色 | 剩余 51–100% |
| 橙色 | 剩余 21–50% |
| 红色 | 剩余 0–20% |

> 文字仅显示服务端返回且能确认的额度窗口。缺失或无法确认的窗口以灰色轨道表示未知，不会被解释为无限额；剩余为 0% 时显示淡红色轨道。

## 工作原理

MauQuota 不启动 Codex CLI 或 Codex App Server。所有网络请求由 Swift <code>URLSession</code> 发起。

### 登录与凭据

1. 生成随机 PKCE verifier、challenge 和 state。
2. 在 <code>127.0.0.1:1455</code> 启动一次性 OAuth 回调监听。
3. 打开 <code>auth.openai.com</code> 官方授权页面。
4. 用户在浏览器完成 ChatGPT 登录后，授权码回调到本机。
5. MauQuota 使用授权码和 PKCE verifier 交换 Token。
6. Access Token、Refresh Token、账号 ID 等信息保存在 macOS Keychain。

MauQuota 不读取 Codex CLI 的 <code>auth.json</code>，也不会修改其他 Codex 客户端的凭据。退出应用不会删除 Keychain 中的登录状态；重新登录会更新本应用自己的凭据。

### 额度与重置接口

当前实现使用以下 ChatGPT Web Backend 接口：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | <code>/backend-api/wham/usage</code> | 读取套餐、5 小时和每周额度 |
| GET | <code>/backend-api/wham/rate-limit-reset-credits</code> | 读取重置卡数量和详情 |
| POST | <code>/backend-api/wham/rate-limit-reset-credits/consume</code> | 使用指定重置卡 |

所有请求均携带 OAuth Bearer Token 和 ChatGPT Account ID。Token 过期后会尝试刷新一次。重置请求使用持久化幂等键；网络结果不确定时，安全重试会复用原请求编号，避免创建新的重复操作。

**兼容性说明：** 上述 <code>/backend-api/wham/*</code> 是 ChatGPT 网页端使用的后端接口，不是承诺长期稳定的公开 REST API。OAuth 客户端配置也沿用当前 Codex CLI 使用的公开客户端标识。OpenAI 可以随时调整授权策略、接口字段或访问权限；如果发生变化，需要更新 MauQuota。MauQuota 不会绕过账号权限或服务端限额。

## 构建与运行

要求 macOS 13+（Apple Silicon / Intel）与 Xcode 命令行工具：

<pre><code>xcode-select --install</code></pre>

从源码构建并启动：

<pre><code>git clone https://github.com/MauriceLiang/MauQuota.git
cd MauQuota
swift run -c release MauQuota</code></pre>

程序以菜单栏应用方式运行，没有主窗口，也不占用 Dock。图标资源位于 <code>Resources/</code>。

GitHub Actions 会运行 Swift 测试，并分别构建 Apple Silicon（arm64）和 Intel（x86_64）版本的 DMG。预览版会发布为 GitHub Pre-release，正式版仍通过 <code>v*</code> 稳定标签发布，并附带 SHA-256 校验文件。

DMG 为 ad-hoc 签名、未经 Apple 公证，首次运行可能出现 Gatekeeper 提示。

## 使用

1. 下载并启动 MauQuota。
2. 从菜单栏选择「使用 ChatGPT 登录…」。
3. 在系统浏览器完成官方授权，回到 MauQuota 等待额度加载。
4. 可随时点击「立即刷新」；查询异常时使用「复制诊断信息」。

本地 OAuth 回调使用 TCP 端口 <code>1455</code>。如果该端口已被其他程序占用，登录会明确提示端口冲突。

MauQuota 使用 <code>URLSession</code> 的系统网络配置。Finder 启动的应用通常会使用 macOS 系统代理设置；仅写在 <code>.zshrc</code> 中的代理环境变量不保证被 GUI 应用继承。

## 测试

<pre><code>swift test</code></pre>

核心逻辑（直接额度响应解析、OAuth PKCE、Token 刷新、Keychain 凭据管理和重置请求映射）均有单元测试覆盖。网络测试使用本地 URLProtocol Stub，不会消耗真实额度或重置卡。

## 版本记录

**v2.0.0-preview.1**

- 移除内置 Codex App Server 及其架构下载、校验和运行时探测。
- 原生实现 ChatGPT OAuth Authorization Code + PKCE 和本地回调。
- 将 OAuth 凭据独立保存到 macOS Keychain。
- 使用 Swift URLSession 直接读取 Codex 额度、查看重置卡和执行重置。
- 加入 Token 自动刷新、401 重试、错误分类和直接 API 响应解析。
- 保留原有菜单栏双环、双语、刷新间隔、重置卡界面、幂等重试与本机重置历史。
- GitHub Actions 不再下载或打包外部运行组件，继续提供 arm64 和 x86_64 DMG。

**v1.9.0**

- 新增使用限额重置、重置卡列表与本机重置历史。
- 内置官方 Codex App Server，以支持浏览器登录、额度读取和重置。
- 加入持久化幂等键与安全重试。

**v1.8.5**

- 彩色额度数字菜单新增红色数字视觉偏移补偿开关，默认关闭。

**v1.8.0**

- 菜单栏额度数字可显示与对应圆环一致的颜色，并可独立开关。

**v1.7.0**

- 菜单栏双环根据各自的剩余额度显示绿色、橙色或红色，未知和耗尽状态也有区分。

**v1.6.0**

- 正式更名为 **MauQuota**，Bundle ID <code>dev.mau.mauquota</code>。
- 首次启动自动迁移旧版 <code>dev.mau.codexmeter</code> 的三项设置，不复制任何凭据。
- 修正启动台图标比例，重新生成完整图标集。

## 许可

[Apache License 2.0](LICENSE)。MauQuota 不随应用分发 Codex CLI、Codex App Server 或其他第三方运行时。本项目与 OpenAI 无关联。
