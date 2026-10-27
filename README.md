> ⚠️ **This is a modified version, not stock FlClash.**
>
> This fork is based on FlClash v0.9.2 (Mihomo core) and adds a
> **per-service country lock + anchor memory + purity/distance ranking**
> smart routing system on top of it. Everything else in the original README
> below (download, build, support, license) is unchanged.
>
> **The problem it solves, in one paragraph:** with stock rule-based routing,
> services like Claude, ChatGPT, Gemini, Cloudflare and Netflix can land on a
> node in a different country and city on every launch, and a jumping login
> location is what triggers risk-control bans; the stock `fallback` group also
> flaps back and forth whenever the primary node recovers. This fork locks each
> service to its own country, remembers the city and ASN where it last landed
> stably, ranks nodes by how clean they are and how close they are to that
> anchor, and fails over stickily — once it moves away, it never switches back.

# Smart Anchor (new features in this fork, in detail)

## Default state: everything off, stock behaviour unchanged

- Every new feature is off by default: no rule, group or DNS entry is injected,
  and traffic follows the original subscription exactly as before.
- Only a service explicitly enabled in settings takes the smart path below;
  disabling it restores the original rules at once, with its anchor frozen and
  kept for re-enabling.

## 1. Per-service country lock: each service locks its own country

- Claude, ChatGPT, Gemini and Cloudflare default to a US lock and enabled;
  Netflix defaults to a Singapore lock but disabled; Google, YouTube and X
  default to disabled with no lock.
- The lock country is chosen by the user in advance and does **not** have to
  equal the anchor country. Three modes: no lock (0 countries — no country
  filtering, login location may jump across countries, highest risk-control
  risk), single-country lock (the default — fixed login country, lowest risk;
  if that country has no usable node, only the tail emergency pool remains),
  and multi-country lock (risk in between).
- Changing the lock country clears the old anchor, because the old anchor's
  city/ASN belongs to another country.
- Effect: a service stops logging in from a different country every time, which
  removes a major trigger for risk-control bans.

## 2. Anchor memory: remember where it last landed stably

- The last stable egress IP's latitude/longitude, ASN and /24 subnet are kept
  across sessions. The next start ranks around that anchor: the original node
  first, then same-subnet, same-ASN and same-city clean nodes, then nearby cities.
- Anti-poisoning: a new node only overwrites the anchor after carrying real
  service traffic stably for 10 minutes; if 3 switches happen within 10 minutes
  in one session, anchor updates freeze and the last healthy anchor is kept.
- Effect: the login city stays put instead of drifting on every restart.

## 3. Purity and distance ranking: not latency

- Hard filter first (any failure drops a node to the emergency pool only):
  country outside the lock, WAF failure, or purity below 50.
- Then `priority = purity − distance penalty + 15 (same ASN) + 10 (same /24)`.
  Purity = 100 − IP-type deduction − fraud score × 0.5 − abuse deduction
  (residential/ISP 0, business 10, hosting/datacenter 30, public proxy/Tor/abuse
  history 25; bands: ≥70 safe, 50–70 occasional risk-control, <50 high risk).
  Distance penalty = min(25, 4 × ln(distance/50 + 1)) km from the anchor
  (about 2.7 points at 50 km, 9.6 at 500 km, 16.5 at 3000 km, capped at 25).
  Delay is only a tie-break when electing a cold-start anchor.
- Effect: nodes are picked for being clean and close to where the service last
  saw you, not merely for being fast.

## 4. Multi-source aggregation: never trust a single source

- Several free lookup sources are queried and aggregated: country by majority
  vote, latitude/longitude averaged only over sources agreeing with the
  consensus country, ASN by same-country majority, IP type takes the strictest
  value, fraud score takes the maximum, any source reporting abuse counts as
  abuse, and country disagreement is flagged `countryDisputed`.
- Free API keys are pooled round-robin (a key hitting 429/quota is cooled for
  the day) and results are cached locally for 72 hours, so cached IPs cost no
  quota and cold start is not blocked.
- Effect: one bad or stale data source can no longer misrank a node.

## 5. Per-node × per-service connectivity: tested per service, not per country

- Geo and purity are per-node, but whether a node can reach a service is per
  node × service: the same Hong Kong node can reach YouTube but not Gemini, and
  GPT's web chain (`chatgpt.com`) and API chain (`api.openai.com`) can differ,
  so each service is probed on both chains separately.
- Only a region-block result removes a node from that service's ranking;
  network failures and service-side outages never permanently exclude a node,
  and a service-outage guard stops failover from blaming nodes when the service
  itself is down. Connectivity cache is about 24 hours.
- Effect: no more country-wide assumptions that break one service while another
  works, and no wrongful switching during a service outage.

## 6. Sticky failover: never switch back

- The in-use node is probed every 30 seconds; only 2 consecutive timeouts count
  as failure, the next ranked node takes over, and the old node is never returned
  to even if it recovers. The anchor is updated only after 10 stable minutes.
- Effect: the flapping of the stock `fallback` group is gone.

## 7. Multi-subscription aggregation: pool nodes from several subscriptions

- One dead subscription no longer forces a manual switch: each source updates
  independently and only a successful parse replaces its old nodes; the merged
  set is rebuilt only when it actually changes.
- Two switchable group modes: primary-only (keep only the primary subscription's
  groups and rules, other sources contribute nodes) and merge-all (same-name
  same-type groups merge, same-name different-type groups are renamed
  `[source label] name`, rules concatenated primary-first and de-duplicated).
  Both modes add a `🔗 聚合全部节点` unified group, and DNS always comes from
  the primary subscription only.

## 8. Config injection: only when enabled

- An enabled service gets a `🎯 Smart-<SERVICE>` select group at the top, its
  match rules prepended ahead of all original rules, and a `nameserver-policy`
  entry pointing its domains at that group. A disabled service gets nothing.

## 9. Device-level diagnostics: shown only, never ranked on

- DNS leaks (any DNS egress country ≠ proxy country) and WebRTC leaks (any
  WebRTC IP ≠ proxy egress IP) are device-level problems (browser/system traffic
  bypassing the proxy), not a node problem, so they are diagnostics only and
  **do not affect node ranking**.

## Implementation status (this fork, right now)

- [x] Step 1 wiring: ranking, locking, aggregation and injection logic wired
  into profile generation, behind the default-off switch; custom
  (non-subscription) profiles are not wired yet.
- [x] Step 2 persistence: anchors, node data and connectivity results in storage.
- [x] Step 3 real probing: through-tunnel egress and per-service probing.
- [x] Step 4 UI: settings page + homepage cards (cards show status and quick
  toggles only; details live in settings).
- [x] Service groups and multi-country lock: same-company services (Google, YouTube, Gemini) can share one set of locked countries and one anchor, toggled per group; locked countries are now a list per service group, synced across members while sharing is on.
- [x] ip.net.coffee merge: Cloudflare edge info (colo/WARP/protocol) and official service status (Claude/OpenAI/Cloudflare) in diagnostics; DNS/WebRTC leaks stay device-level diagnostics, global Ping stays latency display only.
- [x] Auto-failover switch and anti-bounce guard: auto-switching can be turned off; when on, a switch needs two consecutive failures of the node in use, never targets a region-blocked node, never follows a ranking change alone, a manual switch resets the failure count, and at most three switches happen per service in ten minutes before failover freezes in place. Lock or no lock, the rule is the same: a locked service only switches within its locked countries, an unlocked service switches by purity and anchor distance.
- [x] More presets and user-editable services: Copilot, Meta AI, Grok, Perplexity, Mistral, Poe, DeepSeek, Kimi, Doubao, Qwen, ChatGLM, ERNIE, Yuanbao, Disney+ and Apple TV+ presets, all off by default; any preset or custom service can be edited from the services list (name, match rules, DNS domains, lock countries), and custom services can be added or deleted like scripts and subscriptions are edited.
- [ ] After all features, a user-perspective review pass; Windows version later
  (Android first).

## Where the new code lives

- Smart routing logic: `lib/smart_anchor/` (models, scoring engine, country lock,
  service connectivity, sticky monitor, subscription merger, config injector,
  API key pool, diagnostics)
- Wiring point: `getProfile` in `lib/providers/actions/setup.dart`,
  state in `lib/providers/smart_anchor.dart`
- Unit tests: `test/smart_anchor/`

---

<div align="center">

<img src="assets/images/icon.png" alt="FlClash" width="88">

# FlClash

A multi-platform proxy client based on ClashMeta. Simple to use, open source and ad-free.

**English** · [简体中文](README_zh_CN.md)

[![Release](https://img.shields.io/github/v/release/chen08209/FlClash?style=flat-square&label=release)](https://github.com/chen08209/FlClash/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/chen08209/FlClash/total?style=flat-square&logo=github)](https://github.com/chen08209/FlClash/releases)
[![License](https://img.shields.io/github/license/chen08209/FlClash?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-channel-26A5E4?style=flat-square&logo=telegram&logoColor=white)](https://t.me/FlClash)

[Website](https://chen08209.github.io/FlClash) · [Download](#download) · [Changelog](CHANGELOG.md) · [Build from source](#build-from-source)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash dashboard on a MacBook and a phone" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## Features

- **One app for Android, Windows, macOS and Linux**, with x64 and ARM64 builds on the desktop.
- **mihomo (Clash.Meta) core** with rule routing, proxy groups, latency tests, system proxy and TUN mode.
- **Profiles** from a subscription link or a file, with a built-in editor, override scripts, and custom rules,
  proxies and proxy groups.
- **Live views** of connections, requests, DNS queries and logs.
- **Material You design with Apple-style interaction**: dynamic color, light and dark themes, continuous corners,
  sheets that snap between heights, and layouts that adapt from phones to desktops.
- **Backup and restore** through WebDAV or a local file.
- **Platform touches**: a Quick Settings tile, per-app proxy and Android TV support on Android; a tray menu and
  global hotkeys on the desktop.
- **Open source and ad-free**, licensed under GPL-3.0.

## Download

Get the latest build from [GitHub Releases](https://github.com/chen08209/FlClash/releases/latest), or open the
[website](https://chen08209.github.io/FlClash#download), which picks the right file for your device.

| Platform | Packages | Notes |
| --- | --- | --- |
| Android | APK for `arm64-v8a`, `armeabi-v7a` and `x86_64` | Most phones use `arm64-v8a`. Also on the F-Droid repository below. |
| Windows 10 and later | Installer (`.exe`) or portable `.zip`, for x64 and ARM64 | Pick ARM64 on Snapdragon and other ARM laptops. |
| macOS 12 and later | DMG for Apple Silicon and Intel | Also on Homebrew. |
| Linux | `.deb`, `.rpm` and AppImage, for x64 and ARM64 | See the tray note below. |

<p>
  <a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" height="56"></a>
  <a href="https://github.com/chen08209/FlClash/releases/latest"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" height="56"></a>
</p>

**Homebrew**

```bash
brew tap chen08209/tap
brew install --cask flclash
```

**Linux tray icon**

The `.deb` package installs its own dependencies. With the AppImage or the `.rpm`, install the AyatanaAppIndicator
library so the tray icon can show:

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian and Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**Unattended desktop**

FlClash starts the core only after the disclaimer is accepted. Where nobody can click it, such as a container, set
`FLCLASH_ACCEPT_DISCLAIMER=1` in the app's environment to accept it on first launch.

## Usage

**Import a profile from a link.** Opening a link in this form imports the subscription into FlClash. The `clashmeta://`
and `flclash://` schemes work the same way.

```text
clash://install-config?url=<URL-encoded subscription link>
```

**Automate on Android.** Tasker, MacroDroid and similar apps can start, stop or toggle the proxy by starting an
activity with one of these actions:

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

From a computer, the same works over adb:

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## Build from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 (release builds use 3.47.6),
[Go](https://go.dev/dl/) 1.27 and [Rust](https://rustup.rs/) installed through rustup. Each platform builds on its own
host, except Android, which builds anywhere.

```bash
git clone --recursive https://github.com/chen08209/FlClash.git
cd FlClash
flutter pub get
dart setup.dart android   # or windows, macos, linux
```

Packages land in `dist/`. The Go core and the Rust libraries are compiled as part of the Flutter build.

| Platform | Also needed |
| --- | --- |
| Android | Android SDK with the NDK. Add `--arch arm64` to build a single ABI. |
| Windows | GCC (MinGW-w64) for the core and [Inno Setup](https://jrsoftware.org/isinfo.php) 6 for the installer. |
| macOS | Xcode and Node.js. The script installs `appdmg` through npm. |
| Linux | Debian or Ubuntu. The script installs the build packages with apt and downloads `appimagetool`. |

Run `dart setup.dart --help` for the remaining options, such as `--targets` to build only some package formats.

## Support

Starring the repository is the easiest way to support the project. Questions and announcements go to the
[Telegram channel](https://t.me/FlClash); bugs and feature requests go to
[GitHub Issues](https://github.com/chen08209/FlClash/issues).

<a href="https://star-history.com/#chen08209/FlClash&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=chen08209/FlClash&type=Date&theme=dark">
    <img alt="Star history" src="https://api.star-history.com/svg?repos=chen08209/FlClash&type=Date" width="640">
  </picture>
</a>

## License

FlClash is released under the [GPL-3.0 license](LICENSE).
