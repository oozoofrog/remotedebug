# RemoteDebug

[한국어](README.ko.md)

RemoteDebug sends Debug (development-signed) builds from your Mac to your iPhone over Tailscale. The Mac app checks and publishes builds; the paired iPhone app lists them and installs them with the iOS installer. Both apps run a [Swiftail](https://github.com/oozoofrog/Swiftail) node (a Swift implementation of a Tailscale node), only devices you approve can connect, and only development-signed Debug builds are published. The Debug configuration is proven by the build folder name (`Debug-iphoneos`) or an `*.debug.dylib` inside the app; if neither is present, you confirm it in a dialog.

The detailed documents under `docs/` are written in Korean.

RemoteDebug is free. To support its development, you can sponsor it on [GitHub Sponsors](https://github.com/sponsors/oozoofrog).

## For AI agents

### Using RemoteDebug from an agent

The Mac app's **에이전트에 설치…** (Install for agents) adds an MCP server named `remotedebug` and a skill to Claude Code and Codex. The MCP server is the same Mac app binary started with `--mcp`; it forwards commands to the running app.

| Tool | What it does |
| --- | --- |
| `remotedebug_status` | Whether the Mac is sharing, the install page address, connected projects with the version and build number each last published |
| `remotedebug_schemes` | Connect an Xcode project (`project_path`) and list its schemes |
| `remotedebug_feedback_setup` | The code to add crash and feedback reporting to an app (with this Mac's address and the project's public key) and the steps. `project_path`, optional `email` |
| `remotedebug_build` | Build `project_path` (optional `scheme`) for device in Debug and publish it. Waits until the build ends. `report.notes` in the response lists what to check: a changed binary under an unchanged version, a lowered build number, a profile about to expire, sharing turned off |
| `remotedebug_pairing_code` | Open a 5-minute pairing code for an iPhone without the app. Returns the code and the install page link (`installPage`) |
| `remotedebug_pair_requests` | Pairing requests waiting for approval (device name, tailnet node name, login, expiry) |
| `remotedebug_pair_decide` | Deny a request (`request_id`). It cannot approve: approval is only possible on the Mac app's screen |
| `remotedebug_device_logs` | Diagnostic logs the iPhone app sent (app start, VPN, pairing, build list, install, update) |
| `remotedebug_crash_logs` | Crash reports the iPhone sent: the list, or one report's text |
| `remotedebug_push_file`, `remotedebug_push_link` | Send a file (`file_path`) or link (`url`, optional `title`) to the paired iPhone. Optional `project` (a connected project's name or its `.xcodeproj`/`.xcworkspace` path) puts it in that project's area; without it the item goes to the common area |
| `remotedebug_files` | List what was sent, each item with its project area. Optional `project` filters by area |

Without MCP, the same commands go through `~/Library/Application Support/RemoteDebug/agent/rd` (`rd status`, `rd build <project> [scheme]`, `rd pair`, `rd requests`, `rd deny <id>`, `rd push <file> [project]`, `rd link <url> [title] [project]`, `rd files [project]`).

Rules for agents:

- The Mac only publishes. The person taps **설치** (Install) on the iPhone.
- A pairing request is approved only on the Mac app's screen. Agents can list pending requests and deny them. When the person says they just requested pairing, tell them to approve it on the Mac after checking that the node name matches (the RemoteDebug app uses `rd-phone-<8 chars>`).
- Pairing codes and Tailscale keys are secrets. Agent responses never include the Tailscale key, so the pairing link you get still needs a Tailscale login on the iPhone.
- When something fails on the iPhone, read `remotedebug_device_logs` first.

### Working on this repository

- Requirements: Apple silicon Mac, Xcode. Nothing else needs to be built first. `RemoteDebug.xcodeproj` is in the repository; edit targets and build settings in Xcode. SwiftPM and Xcode fetch [Swiftail](https://github.com/oozoofrog/Swiftail) (BSD-3-Clause) from its public repository at a pinned revision, so the first build needs network access. The revision is set in two places that must change together: the package reference in `RemoteDebug.xcodeproj/project.pbxproj` and `Packages/SwiftailHost/Package.swift`.
- To build against a local Swiftail checkout: set `SWIFTAIL_PATH=<path to the checkout>` for SwiftPM commands (the folder must be named `Swiftail`). In Xcode, drag the `../Swiftail` folder (next to this repository) into the project navigator; the local copy overrides the remote package of the same name. Do not commit that change.
- Test-link build (adds test-only tools such as `remotedebug://test?…` links; do not distribute it): put `RD_EXTRA_SWIFT_CONDITIONS = RD_TEST_LINKS` in `Config/Signing.local.xcconfig`. It adds the `RD_TEST_LINKS` compilation condition to `RemoteDebugPhone`, `RemoteDebugTunnel`, and `RemoteDebugVPNTunnel`; with the default empty value the build is unchanged.
- Tests: `swift test --package-path Packages/PhoneClient`, `swift test --package-path Packages/RemoteDebugKit`, `swift test --package-path Packages/SwiftailHost`, `swift test --package-path Packages/WebPage`, `RD_TEST_TMPDIR=<writable folder> swift test --package-path Packages/MacHost`. More in [setup](docs/setup.md#명령줄-빌드와-시험).
- `scripts/check-docs.sh` must pass after editing `README.md` or `docs/`.
- After changing user-visible text, run `scripts/sync-strings.sh` to update the keys of `Localization/Localizable.xcstrings`, then `python3 -I scripts/check_strings.py` to check the translations ([localization](docs/architecture.md#현지화)).
- When documents disagree, follow `docs/tunnel.md`, then `docs/protocol-addenda.md`, then `docs/protocol.md` (details below).
- The iPhone bundle IDs start with `RD_BUNDLE_PREFIX` from `Config/Signing.xcconfig`. The tunnel extension ID is always the app ID plus `.Tunnel`.

## What it does

- **Build and publish**: drop a project folder, `.xcodeproj`, or `.xcworkspace` on the Mac window or Dock icon. The app reads the schemes, builds a Debug device build with `xcodebuild`, and publishes it. Connected projects stay listed, and every Debug device build you make in Xcode is picked up automatically. The app stays in the menu bar after you close the window.
- **Install on iPhone**: the iPhone app shows published builds (grouped by app, with the app icon) and installs them. Over-the-air installs of other apps were confirmed on a real iPhone.
- **Install the iPhone app itself**: **iPhone 앱 설치…** (Install iPhone app) on the Mac builds the iPhone app from this repository with your signing team and installs it on a cabled iPhone ([setup](docs/setup.md#mac-앱으로-iphone-앱-설치)).
- **Updating the iPhone app**: the RemoteDebug app cannot update itself over its own VPN; iOS stops the tunnel during the install. The Mac serves an update page through the official Tailscale app instead ([setup](docs/setup.md#iphone-앱-업데이트)).
- **Pairing**: scan the QR code in the Mac app and approve the request on the Mac. With an optional Tailscale OAuth client, the QR code also carries a one-time Tailscale key so the iPhone joins without logging in ([setup](docs/setup.md#qr-한-번으로-연결tailscale-oauth-클라이언트)). If the iPhone is logged in to a different tailnet than the Mac, the app says so and offers **다른 계정으로 로그인** (log in with another account) ([setup](docs/setup.md#mac과-다른-계정으로-로그인했을-때)). With your own web domain, the pairing link can be an `https://` universal link instead of `remotedebug://pair`, so links that carry the key can be copied too ([setup](docs/setup.md#페어링-링크를-웹-주소로연결-도메인)).
- **Files and links**: drop a file on the Mac's **보낸 파일** (Sent files) screen or push one from an agent; the iPhone receives it in the background and hands it to the Files app or the share sheet. Items can be divided into per-project areas (one for each connected project, plus a common area), and both apps list them by area ([setup](docs/setup.md#mac에서-iphone으로-파일-보내기)).
- **Diagnostic logs**: the iPhone app keeps a log, sends it to the Mac, and the Mac shows it on **iPhone 로그** (iPhone logs).
- **Crash reports**: when the iPhone app crashes, it sends the report to the Mac the next time it runs. For other apps, open the report under iPhone Settings > Privacy & Security > Analytics & Improvements > Analytics Data and share it to RemoteDebug. Both the iPhone app's settings and the Mac's **크래시** (Crashes) screen show and share them.
- **Installed version**: the iPhone build list shows which version of each app is installed now. This uses a private iOS API, so nothing is shown on devices where it returns no value.
- **Without the iPhone app**: the Mac also serves an install web page at `https://<Mac FQDN>/`. An iPhone running the official Tailscale app opens it in Safari, enters a pairing code, and installs after you approve on the Mac. Not yet tried on a real iPhone ([setup](docs/setup.md#iphone에서-앱-없이-설치웹-페이지)).
- **Getting started**: the Mac's **앱** (Apps) screen shows a **시작하기** (Get started) checklist: connect to Tailscale, open the install address, connect an iPhone, publish the first build.

## Quick start

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # set DEVELOPMENT_TEAM
open RemoteDebug.xcodeproj
```

1. Run the `RemoteDebugMac` scheme on the Mac and press **공유 시작** (Start sharing). Log in to Tailscale in the browser window it opens. MagicDNS and HTTPS certificates must be on for the tailnet.
2. Connect the iPhone with a cable and use **iPhone 앱 설치…** on the **기기** (Devices) screen, or run the `RemoteDebugPhone` scheme from Xcode. The VPN entitlement needs a paid Apple Developer Program team.
3. In the iPhone app, turn on the VPN once and log in with the same Tailscale account as the Mac. After that the app turns the VPN on by itself when it needs the Mac. Scan the pairing QR code from the Mac and approve the request on the Mac.
4. Drop an Xcode project on the Mac window. Tap **설치** on the iPhone.

The check scripts for IPA packaging (`scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh`) call `eyebuild`; without it, create the [stand-in script](docs/setup.md#eyebuild가-없는-mac) first. Tailnet policy, signing, and troubleshooting are in [setup](docs/setup.md).

Updating from an earlier build: the Mac logs in to Tailscale again and every iPhone logs in and pairs again; the earlier login and pairings are not carried over ([details](docs/setup.md#이전-버전에서-업데이트한-뒤)).

## VPN: automatic on and off, direct or relayed

Traffic between the Mac and the iPhone goes through the tailnet, which on the iPhone means the VPN, unless both are on the same network and the [direct connection](#same-network-direct-connection-no-vpn) below is available. On the tailnet, when both are on the same network Tailscale connects them directly instead of through a relay server.

- **Automatic on**: when the app needs the Mac (refreshing the build list, installing, receiving a file, sending logs, crashes or feedback, pairing from a link) and no VPN is up, it turns its own VPN on, waits up to 15 seconds, and shows "VPN 켜는 중…". It does this only when its VPN configuration already exists and is the selected one. It never triggers the iOS "Add VPN Configurations" prompt, never switches away from another selected VPN, and never replaces another app's running VPN; those stay behind the buttons.
- **Automatic off**: a VPN the app turned on by itself is turned off after 30 seconds without an install (including one waiting in the iOS installer), a file transfer, or a send. A VPN you turned on yourself, or another app's VPN, is left alone.
- **Path**: the VPN card shows "연결됨 · 직접 연결(같은 네트워크)" (direct, same network), "연결됨 · 직접 연결" (direct), or "연결됨 · 중계 서버 경유" (through a relay).
- **On Demand (optional, off by default)**: Settings > "Mac에 연결할 때 VPN 자동으로 켜기(주문형)" saves an iOS On Demand rule for the paired Mac's address. With it on, iOS turns the VPN back on even after you turn it off.

## Same-network direct connection (no VPN)

When the Mac and the iPhone are on the same Wi-Fi, the iPhone app talks to the Mac directly, without the VPN: build list, file list and downloads, logs, crashes and feedback. When that is not possible the app falls back to the VPN path above and turns the VPN on by itself. Details are in [docs/protocol-addenda.md, section O](docs/protocol-addenda.md#o-같은-네트워크-직접-연결).

- **How it connects**: the Mac opens a second HTTPS port for private and link-local addresses only and advertises it over Bonjour (`_remotedebug._tcp`) under a random id, with no Mac name or tailnet address in the advertisement. The iPhone enrolls once over the tailnet and gets a device token and the listener's public-key pin. After that it connects to `https://<Mac LAN IP>:<port>`, accepts only that key, and sends the token inside TLS 1.3.
- **Installing still uses the VPN**: the iOS installer (`itms-services`) only downloads from an HTTPS address with a system-trusted certificate, and only the tailnet name has one. Tapping install turns the VPN on automatically, also while the direct connection is in use.
- **Fallback**: on a connection error the app looks for the Mac once more, then sends the request over the VPN and does not look again for 60 seconds. It looks again when the network changes or the app comes back to the foreground. If the iOS local network permission is denied the app uses the VPN path without asking again.
- **Screens**: the VPN card shows "직접 연결(같은 Wi-Fi, VPN 없이)" (direct, same Wi-Fi, no VPN). The Mac app's Settings window (⌘,), **고급** (Advanced) tab, has the switch "같은 네트워크에서 직접 연결" (on by default) and shows the port; the **기기** (Devices) screen marks enrolled devices.
- **What changes for security**: anyone on the same LAN can reach the direct port's TLS, where before they had to be on the tailnet. Using the API needs a paired device's token; every other request gets `403`, and the direct port has no pairing, enrollment, install or web page. Tailscale ACLs do not apply to the direct path. Turn the switch off on the Mac if that is not acceptable.
- **Limits**: a file received over the direct path is downloaded only while the app is running (interrupted downloads resume); the VPN path keeps using the system background session.

Push notifications: the Mac app can notify the iPhone app (APNs development environment) when a new build is published or a file or link is added. It needs an APNs auth key set up in the Mac app's Settings window (⌘,), **알림** (Notifications) tab; see [docs/setup.md](docs/setup.md#iphone-알림새-빌드파일) and [addenda P](docs/protocol-addenda.md#p-새-빌드파일-알림apns). Pulling a notification down shows action buttons (Install, Open link, Download) that act on the item directly. Verified on a real iPhone (iOS 27.2): delivery, the tap that opens the matching tab, and the Install and Open link buttons.

Not verified on a real iPhone: the local network permission prompt, connecting to the pinned self-signed certificate under App Transport Security, sharing the token between the two iPhone apps through the Keychain, and the macOS firewall prompt. Unit tests and a loopback TLS test on the Mac pass.

None of this has been verified on a real iPhone; only unit tests and simulator builds pass. Rules and the status field are in [protocol addenda N](docs/protocol-addenda.md#n-vpn-자동-켜기와-경로-표시).

## Two iPhone apps: RemoteDebug and RD 업데이트

Install two apps on the iPhone. Both can run the same VPN and appear as the same tailnet device (the Tailscale state and the paired Mac live in a shared App Group).

- **RemoteDebug** (scheme `RemoteDebugPhone`): installs builds of other apps, receives files, collects crashes and feedback. Pairing with the Mac happens here. Its own builds are not listed.
- **RD 업데이트** (scheme `RemoteDebugVPN`): the updater. It lists only the RemoteDebug builds published on the paired Mac and installs them. It also turns the VPN on and off and handles the Tailscale login.

iOS runs one VPN at a time. When one app turns its VPN on the other one stops, and the Mac pairing stays because the device identity is the same. iOS stops an app and its VPN while that app is being installed, so each app is installed by the other one.

- Updating RemoteDebug: open RD 업데이트 and tap the install button on the RemoteDebug build. If the VPN is not the updater's own, it first moves the VPN to itself, shows each step, then installs. When a newer build exists, RemoteDebug shows a note and an **RD 업데이트 열기** button above the build list.
- Updating RD 업데이트: install it from its own section in RemoteDebug (separate from the build list). If the updater holds the VPN, RemoteDebug takes the VPN over first, then installs.
- The connection screen in RemoteDebug (tap the status line with the Mac name) can also move the VPN to the updater or take it back. The button opens the other app, which switches the VPN and returns.
- First install: pair with RemoteDebug first, then install RD 업데이트 from the build list. Both apps share the Tailscale login and the paired Mac through the App Group.
- Updating RemoteDebug without the updater: turn on the official Tailscale app and open the Mac's update page in Safari ([setup](docs/setup.md#iphone-앱-업데이트)).

Switching the VPN between the two apps, sharing the paired Mac, and installing from the updater have not been verified on a real iPhone. Only the simulator builds and unit tests pass.

## Crashes and feedback from your apps

Problems in apps installed through RemoteDebug show up on the Mac, in the Mac app's crash and feedback screen and in the agent tool `remotedebug_crash_logs`.

- RemoteDebug iPhone app: after an abnormal exit it sends the record on the next launch. Settings has a form for sending feedback about RemoteDebug.
- Your app: add this repository (`https://github.com/oozoofrog/remotedebug`) as a Swift package and link `RemoteDebugFeedback`. On the Mac's **앱** (Apps) screen, the app row's More menu > **크래시·피드백 보내기 추가…** (Add crash and feedback reporting) shows the code with the Mac address filled in.

```swift
import RemoteDebugFeedback

RemoteDebugFeedback.start(.init(
    macHost: "<Mac address>",           // builds installed through RemoteDebug send straight to the Mac
    email: "<address for feedback>",    // optional: used when the Mac is unreachable, and by release builds
    publicKeyBase64: "<public key>"     // optional: Debug builds attach encrypted logs and the screenshot to the mail
))
.remoteDebugFeedback(isPresented: $showsFeedback)      // form with text, screenshot, and recent logs
```

- Drop an encrypted mail attachment (`.afdiag`) on the Mac app's crash and feedback screen to open it. The key stays in that Mac's keychain.
- The package needs iOS 17 or later.

- Apps without the package: open the crash record button in the iPhone build list, open iPhone Settings, and share the `.ips` file from Analytics Data into RemoteDebug.

Sending needs the RemoteDebug VPN on the iPhone. Without it the app keeps the record and sends it later. Sending from another app with the package on a real iPhone has not been verified yet.

## Current status

"Confirmed" means only the scope written in the row. Real-device checks used one iPhone (iOS 27.2) on 2026-11-12. Test rows were last run on 2026-11-16 against Swiftail revision `400ec44`.

| Scope | Status | How to reproduce |
| --- | --- | --- |
| Mac host logic (`RDHostLogic`): routes, pairing and allow list, install sessions, shared files, device logs, crashes, push tokens, agent board, install page files, same-network enrollment | Confirmed (tests pass) | `swift test --package-path Packages/SwiftailHost` (suites in `RDHostLogicTests`, e.g. `SessionTests`, `PairingTests`, `ResourceTests`, `DirectTests`, `PushTests`, `AgentTests`, `HardeningTests`, `WebTests`) |
| Mac host HTTP transport (`SwiftailHostServer`): request parsing, byte ranges, keep-alive connections, manifest and routes, same-network listener, update page server | Confirmed (tests pass) | `swift test --package-path Packages/SwiftailHost` (`HTTPRequestParserTests`, `ByteRangeTests`, `HTTPTransportTests`, `ManifestAndRoutesTests`, `DirectListenerTests`, `UpdatePageTests`, and the iPhone app's pinned transport against the same-network listener in `LogicTransportTests`) |
| Same-network direct connection: iPhone side route selection with fakes | Confirmed (tests pass) | `swift test --package-path Packages/PhoneClient` |
| Same-network direct connection between a real Mac and iPhone | Not confirmed | [Section O.9](docs/protocol-addenda.md#o9-보안-속성과-확인하지-못한-것) |
| Debug build checks and IPA packaging: unit tests, fixtures, real Debug builds of the author's machine | Confirmed | `swift test --package-path Packages/RemoteDebugKit`, `scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh` |
| Mac host core (`SwiftailHostCore`) with a fake node layer, and Mac model + core + logic + HTTP transport over a loopback fake tailnet (`MacHostE2ETests`, test `pairInstallRevokeAndShutdown`). The Swiftail node, TLS and certificates are not part of these tests | Confirmed (tests pass) | `RD_TEST_TMPDIR=<writable folder> swift test --package-path Packages/MacHost` |
| iPhone logic and app: unit tests, simulator build and tests, unsigned device compile | Confirmed | `swift test --package-path Packages/PhoneClient`, [xcodebuild commands](docs/setup.md#명령줄-빌드와-시험) |
| Project connection logic (finding projects, schemes, fake builder, DerivedData suggestions, agent commands, skill and `AGENTS.md`) | Confirmed | `RD_TEST_TMPDIR=<writable folder> swift test --package-path Packages/MacHost` |
| Real iPhone with the RemoteDebug app (confirmed on 2026-11-12 with a build that ran the earlier tunnel engine; not recorded for the Swiftail build): Tailscale login, VPN, pairing, build list, installing other apps (real TLS, `itms-services`), diagnostic logs, receiving files | Partly confirmed | Used by the author. A large file stopped when the app went to the background; the background download fix is not confirmed. Not every step of the [device test procedure](docs/device-test.md) |
| RemoteDebug app updating itself over its own VPN | Fails | iOS stops the tunnel during the install. Use the update page over the official Tailscale app |
| Installing the iPhone app from a page served through the official Tailscale app (`tailscale serve`) | Confirmed with an earlier hand-made page | No record of trying the current update page in the Mac app on a real iPhone |
| Mac app UI by hand: start sharing, pairing sheet, approving a request, network screen, install sheet | Partly confirmed | Window screenshots and accessibility clicks. VoiceOver, dark mode, Dynamic Type not checked |
| Real `xcodebuild` builds of other projects from the Mac app | Confirmed | Builds published by the author's agents |
| Xcode build detection and notification, menu-bar residency and login item, dropping on the Dock icon | Not confirmed | No procedure |
| Install web page: file serving and routes (`WebTests`), `logic.js` and `install.js` in JavaScriptCore. There is no test in a browser engine | Confirmed (tests pass) | `swift test --package-path Packages/SwiftailHost`, `swift test --package-path Packages/WebPage` |
| Install web page in Safari on a real iPhone through the official Tailscale app | Not confirmed | [D14](docs/device-test.md#d14-설치-웹-페이지공식-tailscale-앱) |
| One-time Tailscale key in the pairing QR (OAuth client, real Tailscale API) | Not confirmed | Logic tested with a fake API |
| Mac app installing the iPhone app on a cabled iPhone | Not confirmed | Logic tested with fake tools; bundle IDs per prefix checked with `xcodebuild -showBuildSettings` |
| **다른 계정으로 로그인** (log in with another account) on a real iPhone | Not confirmed | Simulator tests of the reset option |
| Debug confirmation dialog | Not confirmed | [D13](docs/device-test.md#d13-debug-확인-대화상자) |
| Swiftail node in the Mac app and in the packet tunnel on real devices (login, certificates, routes, DNS, memory) | Not recorded here | [Device test procedure](docs/device-test.md) |
| Network Extension limits (memory, routes, DNS details) | Not confirmed | [Device test procedure](docs/device-test.md) |
| Real FSEvents for watched folders; reopening a watched folder after relaunch | Not confirmed | Tests run with FSEvents off |
| Connections lasting hours; reuse after a Mac restart | Not confirmed | No procedure |
| Xcode canvas previews of the iPhone app | Fails to render | See "Known limitations" |

## Layout and documents

| Kind | Name | Location | Contents |
| --- | --- | --- | --- |
| Target | `RemoteDebugMac` | `Apps/Mac` | Mac app entry point and lifecycle |
| Target | `RemoteDebugPhone` | `Apps/iOS` | iPhone app screens and VPN management |
| Target | `RemoteDebugTunnel` | `Apps/iOSTunnel` | Packet tunnel extension |
| Target | `RemoteDebugWidgets` | `Apps/iOSWidgets` | Live Activity for file transfers |
| Package | `RemoteDebugKit` | `Packages/RemoteDebugKit` | Shared models, Debug build checks, IPA and manifest creation, `rdvalidate` |
| Package | MacHost | `Packages/MacHost` | `MacHostKit` (logic, `HostCore` protocol), `MacHostCore` (`SwiftailHostCore`: the Swiftail node and host logic behind `HostCore`), `MacHostUI` (screens and previews, does not link Swiftail) |
| Package | SwiftailHost | `Packages/SwiftailHost` | `RDHostLogic` (routes, pairing, sessions, shared files, install page files), `SwiftailHostServer` (HTTP transport, same-network listener, update page server), `rd-swiftail-host` (gate and test tool) |
| Package | PhoneClient | `Packages/PhoneClient` | iPhone app logic `PhoneClientKit` |
| Package | WebPage | `Packages/WebPage` | JavaScriptCore tests of the install page logic. No product code |
| Dependency | Swiftail | [github.com/oozoofrog/Swiftail](https://github.com/oozoofrog/Swiftail) | Pure-Swift tailnet node used by the Mac host and the iPhone tunnel extensions. Fetched by SwiftPM at a pinned revision |
| Resource | Install web page | `Packages/SwiftailHost/Sources/RDHostLogic/Resources/web` | HTML, CSS, JS the Mac host serves at `/` |
| Scripts | | `scripts/` | Document and string checks, IPA checks, release and iPhone install scripts |

| Document (Korean) | Contents |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Requirements, signing, building, first run, installing the iPhone app, pairing, files, updates, troubleshooting |
| [docs/device-test.md](docs/device-test.md) | Real-device test procedure |
| [docs/device-test-results.md](docs/device-test-results.md) | Real-device result sheet |
| [docs/protocol.md](docs/protocol.md) | Protocol v1 between the Mac and the iPhone, and the Swift boundary to the Mac host node |
| [docs/protocol-addenda.md](docs/protocol-addenda.md) | Rules that amend `docs/protocol.md`: install page (E), icons (F), logs (G), files (H), update page (I), Tailscale key in the pairing link (J) |
| [docs/tunnel.md](docs/tunnel.md) | iPhone packet tunnel |
| [docs/architecture.md](docs/architecture.md) | Structure and initial assumptions. Wrong sentences are listed in "Corrections to the documents" |

When documents disagree, follow this order:

1. `docs/tunnel.md` replaces all of §6 of `docs/protocol.md` and assumption A1 of `docs/architecture.md`.
2. `docs/protocol-addenda.md` takes precedence over `docs/protocol.md` where the tunnel document is silent.
3. The rest of `docs/protocol.md` and `docs/architecture.md`, except what "Implementation that differs from the design documents" and "Corrections to the documents" below say.

## Known limitations

- Apple silicon only. The Mac app builds for arm64 only.
- The VPN entitlement (Network Extension) needs a paid Apple Developer Program team for the iPhone app.
- iOS runs one VPN at a time. While the RemoteDebug VPN is on, the official Tailscale VPN is off, and the reverse.
- The RemoteDebug iPhone app cannot update itself over its own VPN. Use the update page through the official Tailscale app or install from the Mac with a cable.
- Nine on-device items of `docs/tunnel.md` remain unverified; they are U1–U9 in the [device test procedure](docs/device-test.md).
- Xcode canvas previews of the iPhone app fail on the author's machine with `Timed out waiting for signal to perform the initial JIT link`. The cause is unknown. Simulator runs and tests work.
- Mac app previews render, but scenarios that start sharing may show only a progress indicator.
- Restoring an iPhone from backup drops the tunnel state folder (it is excluded from backup), so Tailscale login and pairing must be redone. Not checked on a device ([D6](docs/device-test.md#d6-백업에서-복원)).
- The Mac also excludes its node state (`state`) and `identity.json` from Time Machine and migration. A restored or migrated Mac logs in again as a new node (`rd-mac-<new 8 chars>`) and every iPhone must pair again. Not checked with a real restore.
- A build whose Debug configuration cannot be proven by folder name or `*.debug.dylib` is published after you confirm it. Whether it changed after confirmation is compared by file metadata (path, kind, size, modification time, inode) for `.app` and by SHA-256 for `.ipa`. The `.app` comparison is not a content hash.
- After five wrong pairing codes the host discards the code, but `denied` events are limited to one per five seconds, so the Mac may keep showing the discarded code until the next event. Use **새 코드 만들기** (New code).
- If you quit the Mac app during an import, the import can still write after the storage lock is released. Wait for imports to finish before quitting and reopening.
- Neither app was checked with VoiceOver, dark mode, or Dynamic Type.
- The Mac app does not use App Sandbox. Its storage moved from the sandbox container to `~/Library/Application Support/RemoteDebug` with no migration.
- Project builds started by the Mac app do not pass `-allowProvisioningUpdates`; a project without a profile or with an unregistered device must be built once for device in Xcode. Installing the iPhone app itself does pass it.
- Xcode builds are found through DerivedData's `info.plist` (`WorkspacePath`) and Xcode's build location setting (default, or Custom > Relative to Workspace). Other build location settings are not found.
- Xcode build detection polls `Build/Products/Debug-iphoneos` and build records every three seconds, so it asks after the folder changes, not when the build starts.
- The agent command (`~/Library/Application Support/RemoteDebug/agent/rd`) can list and deny pairing requests; approval is only possible on the Mac app's screen.
- The Mac's **기기** (Devices) screen does not show the connection path (direct or relayed) per device. The iPhone's VPN card still shows it.
- The install web page approves a tailnet node, not a browser. Once approved, every app on that iPhone can reach the Mac. Remove the device on the Mac's **기기** screen to cut access.
- The install web page needs the official Tailscale VPN on the iPhone and HTTPS certificates in the tailnet. A tailnet policy that blocks the iPhone node from the Mac's port 443 blocks the page ([ACL notes](docs/setup.md#tailnet-정책acl)).
- Reloading the install web page does not resume watching an install in progress. The Mac's session expires on its own.

## Implementation that differs from the design documents

The numbers are line numbers in `.agent-loop/remotedebug-bridge/decisions.jsonl`.

| Design document | Current implementation | Evidence |
| --- | --- | --- |
| `docs/architecture.md` assumption A1: a local CONNECT proxy in the tunnel extension | A packet tunnel that relays IP packets to the tailnet ([`docs/tunnel.md`](docs/tunnel.md)). Apple TN3120 discourages listeners and proxies inside a packet tunnel | 5, 26 |
| `docs/architecture.md`: screens in the Mac app target | Screens and previews are in `MacHostUI`, which does not link the node, so previews run without it | 33, 34, 41 |
| `docs/protocol.md` §5: storing allowed devices | Bound to the control server URL that approved them. Changing servers requires pairing again after confirmation | 34, 43 |
| `docs/protocol.md:3`: edit this document first when changing rules | Changed rules are in [`docs/protocol-addenda.md`](docs/protocol-addenda.md). When they differ, follow the addenda | 6 |
| `docs/architecture.md:5`: install only through the node embedded in each app | The embedded path stays; an install web page for iPhones with only the official Tailscale app was added ([`docs/protocol-addenda.md`](docs/protocol-addenda.md) E) at the user's request | 61, 62, 63, 64, 65 |
| `docs/architecture.md:88`: Xcode and TestFlight internal distribution | Direct Xcode install or Ad Hoc | 2 |
| `docs/architecture.md` assumption A3: Mac app with App Sandbox | The alternative in the same table ("switch to non-sandboxed distribution") was chosen | No record (user request, 2026-11-11) |

Current behavior not in the design documents:

- The iPhone tunnel sends only the tailnet suffix and reverse zones to `100.100.100.100`; it does not take over the device's DNS (19, 26).
- The team ID lives in `Config/Signing.local.xcconfig`, which `Config/Signing.xcconfig` includes, so the project file never holds it (38, 39).
- Debug confirmation is bound to a metadata fingerprint of the bundle tree for `.app` (not a content hash) and to SHA-256 for `.ipa`. Bundle ID, version, and build number must also match (40, 43).
- State folders holding node keys are excluded from backup (31, 34, 35).
- A storage lock lets only one Mac app run at a time (34, 44).
- Logic lives in `MacHostKit` and `PhoneClientKit` so it is tested with `swift test` without signing (14, 15).
- The Xcode project `RemoteDebug.xcodeproj` is tracked in git; edit targets and build settings in Xcode (25).
- The Mac app builds only for `ARCHS=arm64` (10).
- Integration tests of the Mac host are `MacHostE2ETests` in `Packages/MacHost`.

## Corrections to the documents

These sentences differ from the implementation. The documents were not edited; follow the right column.

| Location | Sentence in the document | Correct content |
| --- | --- | --- |
| `docs/architecture.md:86` | "iOS itself does not accept OTA installs of distribution-signed IPAs" | iOS installs Ad Hoc and Enterprise IPAs over the air too. Debug-only is enforced by the Mac app's checks (development profile, `get-task-allow`, Debug configuration) and the host's re-check at publish time (`debug`, `getTaskAllow`, size, SHA-256) |
| `docs/architecture.md:87` | "Secrets (auth keys) are stored only in the Keychain" | Tailscale auth keys are not stored; an entered key is passed to the node for the next start only. The optional Tailscale OAuth client is stored in the Mac Keychain. Node state (node key) stays in `stateDir`, which is excluded from backup |
| `docs/protocol.md:17` | "Node names are `rd-mac-<id8>` and `rd-phone-<id8>`." | Only for RemoteDebug app nodes. An iPhone paired through the install web page uses the official Tailscale app's node name |
| `docs/protocol.md:385` | "Allowing only `tcp:443` with tailnet ACL tags (`tag:rd-mac`, `tag:rd-phone`) adds a network-layer barrier" | With only these tag rules, an iPhone on the official Tailscale app (a user node without `tag:rd-phone`) cannot reach the Mac. Follow the [ACL notes](docs/setup.md#tailnet-정책acl) |

## Document check

The script prints its usage in Korean:

```
사용: scripts/check-docs.sh [--help]
```

It prints one line per mismatch and exits with code 1 when any of these differ from the repository: paths in code spans and code blocks (except json) under `scripts/`, `docs/`, `Packages/`, `Apps/`, `Config/`, `.agent-loop/`, and `RemoteDebug.xcodeproj/`; scripts named in the documents; target, scheme, module, and bundle ID names (read from `RemoteDebug.xcodeproj/project.pbxproj`, its shared schemes, `Config/Signing.xcconfig`, and `Packages/*/Package.swift`); U items and the on-device items of `docs/tunnel.md`; D items and the run-order table; relative links and `#` heading anchors; screen text written in bold or double quotes in the install web page procedures (`docs/setup.md` web page section, `docs/device-test.md` D14), compared with the page source `Packages/SwiftailHost/Sources/RDHostLogic/Resources/web` and the Mac app source `Packages/MacHost/Sources`. It also fails when a required document or `scripts/check_protocol_examples.py` is missing. Paths in prose outside code spans are not checked.

## License

MIT. See [LICENSE](LICENSE). The Mac and iPhone apps link [Swiftail](https://github.com/oozoofrog/Swiftail) (BSD 3-Clause), which carries its own third-party notices (`THIRD-PARTY-NOTICES.md` in its repository).
