> ⚠️ **这是修改版，不是原版 FlClash。**
>
> 本分支基于 FlClash v0.9.2（Mihomo 内核），在原版全部功能不变的基础上，
> 增加了一套**“业务锁国 + 锚点记忆 + 纯净度距离排序”智能分流系统**。
> 原版其余所有内容（下载、构建、支持、许可证）都在下面，原样未动。
>
> **一句话说清它解决什么问题：** 原版按订阅规则分流时，Claude、ChatGPT、Gemini、
> Cloudflare、Netflix 这些业务每次打开可能落在不同国家、不同城市的节点上，
> 登录地一跳变就容易触发风控封号；主节点一恢复，原版 `fallback` 组又会反复回切，
> 造成抖动。本分支让每个业务各自锁定国家、记住上次稳定落地的城市和 ASN、
> 按“干净程度 + 离锚点多近”排序选节点，挂了粘性切走、恢复了也不回切。

# 智能锚点分流（本分支新增功能详解）

## 默认状态：全部关闭，原版行为零变化

- 所有新增功能默认都是关闭的：不注入任何规则、不建任何组、不改任何 DNS，
  流量完全走原订阅的规则和 DNS，和原版一模一样。
- 只有在设置里打开某个业务后，该业务才走下面的智能分流；关掉就立刻回到原订阅，
  已有锚点被冻结保留，重开后接着用，不会丢失。

## 1. 业务独立锁国：每个业务锁自己的国家，互不干扰

- Claude、ChatGPT、Gemini、Cloudflare 默认锁美国且默认开启；
  Netflix 默认锁新加坡但默认关闭；Google、YouTube、X 默认关闭且不锁国。
- 锁国由用户提前选定的目标国家决定，**不必等于锚点国家**，三种模式及效果：
  - **0 国不限**：不按国家过滤，登录地可能跨国跳变，风控风险最高；
  - **单国锁（默认）**：登录国家固定，风控风险最低；该国没有可用节点时，
    只剩下尾部应急池，不会偷偷用别国节点；
  - **多国锁（非默认）**：允许在几个国家内选节点，风险介于两者之间。
- **改锁国会清空旧锚点**：旧锚点的城市/ASN 属于另一个国家，留着会误导排序。
- 效果：业务不再今天美国、明天新加坡地换登录地，风控封号的诱因直接少了一大块。

## 2. 锚点记忆：记住上次稳定落地的城市，下次还往那儿找

- 记录上次稳定落地 IP 的经纬度、ASN、/24 网段、城市，跨会话保留。
- 下次启动以这个锚点为圆心找节点：优先原节点，其次同网段、同 ASN、
  同城市的干净节点，最后才是附近城市，层层向外扩散。
- 防污染：新节点必须真实承载该业务流量并稳定 10 分钟，才更新锚点；
  一会话内 10 分钟切换 ≥3 次时冻结锚点更新，保住最后一个健康锚点。
- 效果：登录城市不再每次重启就漂移，业务看到的始终是同一个地方。

## 3. 纯净度与距离排序：不按延迟选节点

- 先硬过滤（一票否决，任一不满足只进尾部应急池）：国家不在锁国范围内，
  或 WAF 不通，或纯净度 < 50。
- 再按公式排序：`优先级 = 纯净度 − 距离惩罚 ＋ 同 ASN 15 分 ＋ 同 /24 网段 10 分 − 延迟惩罚`，延迟惩罚为 `min(10, 延迟毫秒 / 100)`（未测节点记 0 分、超时节点记 10 分），质量和位置都好的节点里，延迟最低的优先。
  - 纯净度 = 100 − IP 类型扣分 − 欺诈分 × 0.5 − 滥用扣分：
    住宅/ISP 扣 0，商业扣 10，机房/数据中心扣 30，公开代理/Tor/滥用记录扣 25；
    分档：≥70 放心，50–70 偶有风控，<50 高危。
  - 距离惩罚 = min(25, 4 × ln(距离/50 + 1))，锚点与节点按球面距离算：
    50 公里约扣 2.7 分，500 公里约扣 9.6 分，3000 公里约扣 16.5 分，封顶 25 分。
  - 延迟只在冷启动选锚点时做同分平局参考，排序本身不看延迟。
- 效果：选的是“干净且离上次登录地近”的节点，而不是单纯最快的节点；
  机房高危 IP 再快也不会排到前面。

## 4. 多源交叉聚合：节点数据不只信一个来源

- 多个免费查询源一起查再聚合：国家多数票，经纬度只对与共识国家一致的源取均值，
  ASN 同国多数票，IP 类型取最严，欺诈分取最大，任一源报滥用即算滥用，
  国家不一致标记 `countryDisputed`；缺国家或缺 IP 的源结果不计入。
- 免费 API Key 轮询使用，某 Key 遇到 429/配额耗尽会被标记“当天冷却”并自动换下一个；
  结果本地缓存 72 小时，缓存命中不消耗配额，冷启动不被阻塞。
- 效果：单个数据源出错或过时，不会再把节点排错。

## 5. 节点 × 服务连通性：按业务分开测，不按国家一刀切

- 国家和纯净度是节点维度的，但节点能不能访问某个服务是“节点 × 服务”维度的：
  同一个香港节点可以访问 YouTube，却不能访问 Gemini；
  GPT 的网页链路（chatgpt.com）与 API 链路（api.openai.com）也可能一个通一个不通，
  所以每个业务的探针分网页链路和 API 链路两条。
- 只有“地区封锁”会把节点从该业务的排序里彻底剔除；
  网络失败和服务方宕机不会永久排除节点，服务方连续宕机时还有断路保护，
  不让切换去怪罪节点。连通性缓存约 24 小时。
- 效果：不再因为“这个国家能用”就误判某个业务，也不会在服务方自己宕机时乱切节点。

## 6. 粘性故障转移：切走就不再回切

- 在用节点每 30 秒探一次，连续 2 次超时才算故障，故障后前进到下一顺位，
  即使原节点恢复也不回切；稳定 10 分钟后才更新锚点。
- 效果：原版 `fallback` 组那种主节点一恢复就反复回切的抖动没有了。

## 7. 多订阅聚合：多个订阅的节点合在一起用

- 一个订阅失效不用手动换订阅：每个订阅独立更新，只有解析成功才替换旧节点，
  单源失败时保留其上次可用节点；节点集真的变化了才触发重建。
- 两种组模式可切换：主订阅模式（只保留主订阅的组和规则，其他源只贡献节点）
  与全部合并模式（同名同类型组合并成员，同名不同类型组改名为
  `[源标签] 组名`，规则按主订阅在前、各源顺序拼接去重）。
  两种模式都会额外生成一个 `🔗 聚合全部节点` 统一组，
  DNS 两种模式都只用主订阅的。
- 效果：订阅池变大了，单个订阅挂掉不再等于断网。

## 8. 配置注入：开启才生效，关闭即原样

- 开启的业务：最前面加一个 `🎯 Smart-业务名` select 组，
  该业务的匹配规则插到所有规则最前面（先匹配先命中），
  DNS 的 `nameserver-policy` 把该业务域名指向这个组。
- 关闭的业务：不注入、不建组、不改 DNS、不监控，流量走原订阅。

## 9. 设备级诊断：只展示，不进排序

- DNS 泄露（任一 DNS 出口国家 ≠ 代理国家）、WebRTC 泄露
  （任一 WebRTC IP ≠ 代理出口 IP）是设备级问题（浏览器/系统绕过了代理），
  不是某个节点的问题，所以只做诊断展示，**不影响节点排序**。

## 实现进度（本分支当前状态）

- [x] 第 1 步 接线：排序、锁国、聚合、注入逻辑已接进配置生成，默认关闭；
  自定义配置（非订阅配置）暂未接线。
- [x] 第 2 步 持久化：锚点、节点数据、连通性结果存库，重启不丢。
- [x] 第 3 步 真正去探：走隧道实际发请求测出口 IP、测各业务连通性。
- [x] 第 4 步 界面：设置页 + 首页卡片；卡片只放状态和快速开关，详情进设置页。
- [x] 服务组与多国锁：分组按地区限制划分，不只看是不是同一家公司——Google 与 YouTube 一组（两者都不拒绝地区），Gemini 独立一组（它拒绝部分地区），受限业务不会把不受限业务绑进同一个锁；锁国改为按服务组存国家列表，共用开启时组内成员同步。
- [x] ip.net.coffee 合并：诊断里加 Cloudflare 边缘信息（机房/WARP/协议）与官方服务状态（Claude/OpenAI/Cloudflare）；DNS/WebRTC 泄露只作设备级诊断，全球 Ping 只作延迟展示。
- [x] 自动切换开关与防反复跳转保护：自动切换可关闭；开启时，每 30 秒循环探测各开启业务的在用节点，在用节点连续 2 次探测失败才切换，绝不切向地区封锁节点，排名变化本身不触发切换，手动切换会清零失败计数，每业务 10 分钟内最多切换 3 次，超限后冻结在原地。锁国与否规则相同：有锁只在锁的国家内切换，无锁按纯净度、锚点距离和延迟切换。
- [x] 更多预设与用户可编辑业务：新增 Copilot、Meta AI、Muse、Grok、Perplexity、Mistral、Poe、Disney+、Apple TV+ 预设，全部默认关闭（国内 AI 有意不做预设，需要的话可按自定义业务添加）；业务列表里点任一业务可编辑（名称、匹配规则、DNS 域名、锁国），自定义业务可新增或删除，方式与脚本/订阅编辑类似。
- [x] 首页节点位置路径示意图：首页卡片按服务组画出节点位置变化路径（每成员一条线，锚点画成菱形，最新节点画圈标出），可切换服务组查看不同组的路径，下方列出最近移动并标注是自动、手动还是首次出现，另有回到锚点和清除路径按钮。在用节点稳定 10 分钟后会自动成为该业务的锚点，锚点不再只是恢复旧值。
- [ ] 全部功能实现后按用户视角检查一遍，再定 Windows 版（目前先做 Android）。

## 新增代码位置

- 智能分流逻辑：`lib/smart_anchor/`（模型、排序引擎、国家锁、服务连通性、
  粘性监控、订阅聚合、配置注入、API 轮询池、诊断）
- 接线点：`lib/providers/actions/setup.dart` 的 `getProfile`，
  状态：`lib/providers/smart_anchor.dart`
- 单元测试：`test/smart_anchor/`

---

<div align="center">

<img src="assets/images/icon.png" alt="FlClash" width="88">

# FlClash

基于 ClashMeta 的多平台代理客户端，简单易用，开源无广告。

[English](README.md) · **简体中文**

[![Release](https://img.shields.io/github/v/release/chen08209/FlClash?style=flat-square&label=release)](https://github.com/chen08209/FlClash/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/chen08209/FlClash/total?style=flat-square&logo=github)](https://github.com/chen08209/FlClash/releases)
[![License](https://img.shields.io/github/license/chen08209/FlClash?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-channel-26A5E4?style=flat-square&logo=telegram&logoColor=white)](https://t.me/FlClash)

[官网](https://chen08209.github.io/FlClash/zh) · [下载](#下载) · [更新日志](CHANGELOG.md) · [从源码构建](#从源码构建)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash 在 MacBook 与手机上的仪表盘" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## 功能

- **一个应用覆盖 Android、Windows、macOS 和 Linux**，桌面端同时提供 x64 与 ARM64 版本。
- **mihomo（Clash.Meta）内核**：规则分流、代理组、延迟测试、系统代理与 TUN 模式。
- **配置管理**：通过订阅链接或文件导入配置，内置编辑器，支持覆写脚本以及自定义规则、代理和代理组。
- **实时查看**连接、请求、DNS 查询和日志。
- **Material You 设计，融合 Apple 式交互**：支持动态取色、浅色与深色主题，连续曲率圆角，弹出面板可在几档高度间吸附，布局随屏幕从手机到桌面自适应。
- **备份与恢复**：通过 WebDAV 或本地文件。
- **平台细节**：Android 上有快捷设置磁贴、分应用代理和 Android TV 支持；桌面端有托盘菜单和全局快捷键。
- **开源无广告**，以 GPL-3.0 协议发布。

## 下载

从 [GitHub Releases](https://github.com/chen08209/FlClash/releases/latest) 获取最新版本，或打开
[官网](https://chen08209.github.io/FlClash/zh#download)，它会自动为你的设备选好安装包。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| Android | `arm64-v8a`、`armeabi-v7a`、`x86_64` 三种 APK | 绝大多数手机选 `arm64-v8a`。也可以通过下方的 F-Droid 仓库安装。 |
| Windows 10 及以上 | 安装版（`.exe`）或便携版（`.zip`），分 x64 与 ARM64 | 骁龙等 ARM 架构笔记本选 ARM64。 |
| macOS 12 及以上 | Apple Silicon 与 Intel 两种 DMG | 也可以通过 Homebrew 安装。 |
| Linux | `.deb`、`.rpm` 和 AppImage，分 x64 与 ARM64 | 托盘依赖见下方说明。 |

<p>
  <a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" height="56"></a>
  <a href="https://github.com/chen08209/FlClash/releases/latest"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" height="56"></a>
</p>

**Homebrew**

```bash
brew tap chen08209/tap
brew install --cask flclash
```

**Linux 托盘图标**

`.deb` 安装包会自动安装所需依赖。使用 AppImage 或 `.rpm` 时，需要先安装 AyatanaAppIndicator 库，托盘图标才能显示：

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian 与 Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**无人值守的桌面环境**

FlClash 要在免责声明被接受后才会启动核心。在容器等无人点击的环境里，可在应用的环境变量中设置
`FLCLASH_ACCEPT_DISCLAIMER=1`，首次启动时即视为接受。

## 使用

**通过链接导入配置。** 打开下面格式的链接，即可把订阅导入 FlClash。`clashmeta://` 和 `flclash://` 开头的链接同样可用。

```text
clash://install-config?url=<经过 URL 编码的订阅链接>
```

**Android 自动化。** Tasker、MacroDroid 等应用可以用下面的 Action 启动 Activity，从而启动、停止或切换代理：

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

在电脑上也可以通过 adb 触发：

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) 3.47（正式版构建使用 3.47.6）、[Go](https://go.dev/dl/) 1.27，
以及通过 rustup 安装的 [Rust](https://rustup.rs/)。桌面端需要在对应系统上构建，Android 在任意系统上都能构建。

```bash
git clone --recursive https://github.com/chen08209/FlClash.git
cd FlClash
flutter pub get
dart setup.dart android   # 或 windows、macos、linux
```

安装包输出到 `dist/`。Go 内核和 Rust 库会在 Flutter 构建过程中一并编译。

| 平台 | 额外依赖 |
| --- | --- |
| Android | 带 NDK 的 Android SDK。加上 `--arch arm64` 可以只构建单个 ABI。 |
| Windows | 编译内核用的 GCC（MinGW-w64），以及打包安装程序用的 [Inno Setup](https://jrsoftware.org/isinfo.php) 6。 |
| macOS | Xcode 与 Node.js。脚本会通过 npm 安装 `appdmg`。 |
| Linux | Debian 或 Ubuntu。脚本会用 apt 安装构建所需的软件包，并下载 `appimagetool`。 |

其余选项可以运行 `dart setup.dart --help` 查看，例如用 `--targets` 只构建部分安装包格式。

## 支持

给仓库点一个 Star 是支持项目最简单的方式。问题讨论和更新通知请关注 [Telegram 频道](https://t.me/FlClash)，
Bug 与功能建议请提交到 [GitHub Issues](https://github.com/chen08209/FlClash/issues)。

<a href="https://star-history.com/#chen08209/FlClash&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=chen08209/FlClash&type=Date&theme=dark">
    <img alt="Star history" src="https://api.star-history.com/svg?repos=chen08209/FlClash&type=Date" width="640">
  </picture>
</a>

## 许可证

FlClash 以 [GPL-3.0 协议](LICENSE)发布。
