# RemoteDebug

[한국어](README.ko.md)

RemoteDebug sends Debug (development-signed) builds from your Mac to your iPhone over Tailscale. The Mac app checks and publishes builds; the paired iPhone app lists them and installs them with the iOS installer. Both apps embed Tailscale, only devices you approve can connect, and only development-signed Debug builds are published. The Debug configuration is proven by the build folder name (`Debug-iphoneos`) or an `*.debug.dylib` inside the app; if neither is present, you confirm it in a dialog.

The detailed documents under `docs/` are written in Korean.

## For AI agents

### Using RemoteDebug from an agent

The Mac app's **에이전트에 설치…** (Install for agents) adds an MCP server named `remotedebug` and a skill to Claude Code and Codex. The MCP server is the same Mac app binary started with `--mcp`; it forwards commands to the running app.

| Tool | What it does |
| --- | --- |
| `remotedebug_status` | Whether the Mac is sharing, the install page address, connected projects |
| `remotedebug_schemes` | Connect an Xcode project (`project_path`) and list its schemes |
| `remotedebug_build` | Build `project_path` (optional `scheme`) for device in Debug and publish it. Waits until the build ends |
| `remotedebug_pairing_code` | Open a 5-minute pairing code. Returns the code and a `remotedebug://pair?…` link (no Tailscale key) |
| `remotedebug_pair_requests` | Pairing requests waiting for approval (device name, tailnet node name, login, expiry) |
| `remotedebug_pair_decide` | Approve or deny a request (`request_id`, `approve`) |
| `remotedebug_device_logs` | Diagnostic logs the iPhone app sent (app start, VPN, pairing, build list, install, update) |
| `remotedebug_crash_logs` | Crash reports the iPhone sent: the list, or one report's text |
| `remotedebug_push_file`, `remotedebug_push_link`, `remotedebug_files` | Send a file or link to the paired iPhone, list what was sent |

Without MCP, the same commands go through `~/Library/Application Support/RemoteDebug/agent/rd` (`rd status`, `rd build <project> [scheme]`, `rd pair`, `rd requests`, `rd approve <id>`, `rd deny <id>`, `rd push <file>`, `rd link <url>`).

Rules for agents:

- The Mac only publishes. The person taps **설치** (Install) on the iPhone.
- Approve a pairing request only when the person says they just requested it and the node name matches (the RemoteDebug app uses `rd-phone-<8 chars>`).
- Pairing codes and Tailscale keys are secrets. Agent responses never include the Tailscale key, so the pairing link you get still needs a Tailscale login on the iPhone.
- When something fails on the iPhone, read `remotedebug_device_logs` first.

### Working on this repository

- Requirements: Apple silicon Mac, Xcode, Go, XcodeGen. Run `scripts/build-core.sh` before building the apps; it builds the Go core into `Packages/RDCore/RDCore.xcframework`.
- Tests: `swift test --package-path Packages/PhoneClient`, `swift test --package-path Packages/RemoteDebugKit`, `RD_TEST_TMPDIR=<writable folder> swift test --package-path Packages/MacHost`, `scripts/go.sh test -race -count=1 ./...`. More in [setup](docs/setup.md#명령줄-빌드와-시험).
- `scripts/check-docs.sh` must pass after editing `README.md` or `docs/`.
- When documents disagree, follow `docs/tunnel.md`, then `docs/protocol-addenda.md`, then `docs/protocol.md` (details below).
- The iPhone bundle IDs start with `RD_BUNDLE_PREFIX` from `Config/Signing.xcconfig`. The tunnel extension ID is always the app ID plus `.Tunnel`.

## What it does

- **Build and publish**: drop a project folder, `.xcodeproj`, or `.xcworkspace` on the Mac window or Dock icon. The app reads the schemes, builds a Debug device build with `xcodebuild`, and publishes it. Connected projects stay listed, and every Debug device build you make in Xcode is picked up automatically. The app stays in the menu bar after you close the window.
- **Install on iPhone**: the iPhone app shows published builds (grouped by app, with the app icon) and installs them. Over-the-air installs of other apps were confirmed on a real iPhone.
- **Install the iPhone app itself**: **iPhone 앱 설치…** (Install iPhone app) on the Mac builds the iPhone app from this repository with your signing team and installs it on a cabled iPhone ([setup](docs/setup.md#mac-앱으로-iphone-앱-설치)).
- **Updating the iPhone app**: the RemoteDebug app cannot update itself over its own VPN; iOS stops the tunnel during the install. The Mac serves an update page through the official Tailscale app instead ([setup](docs/setup.md#iphone-앱-업데이트)).
- **Pairing**: scan the QR code in the Mac app and approve the request on the Mac. With an optional Tailscale OAuth client, the QR code also carries a one-time Tailscale key so the iPhone joins without logging in ([setup](docs/setup.md#qr-한-번으로-연결tailscale-oauth-클라이언트)). If the iPhone is logged in to a different tailnet than the Mac, the app says so and offers **다른 계정으로 로그인** (log in with another account) ([setup](docs/setup.md#mac과-다른-계정으로-로그인했을-때)).
- **Files and links**: drop a file on the Mac's **보낸 파일** (Sent files) screen or push one from an agent; the iPhone receives it in the background and hands it to the Files app or the share sheet ([setup](docs/setup.md#mac에서-iphone으로-파일-보내기)).
- **Diagnostic logs**: the iPhone app keeps a log, sends it to the Mac, and the Mac shows it on **iPhone 로그** (iPhone logs).
- **Crash reports**: when the iPhone app crashes, it sends the report to the Mac the next time it runs. For other apps, open the report under iPhone Settings > Privacy & Security > Analytics & Improvements > Analytics Data and share it to RemoteDebug. Both the iPhone app's settings and the Mac's **크래시** (Crashes) screen show and share them.
- **Installed version**: the iPhone build list shows which version of each app is installed now. This uses a private iOS API, so nothing is shown on devices where it returns no value.
- **Without the iPhone app**: the Mac also serves an install web page at `https://<Mac FQDN>/`. An iPhone running the official Tailscale app opens it in Safari, enters a pairing code, and installs after you approve on the Mac. Not yet tried on a real iPhone ([setup](docs/setup.md#iphone에서-앱-없이-설치웹-페이지)).
- **Getting started**: the Mac's build screen shows a **시작하기** (Get started) checklist: connect to Tailscale, open the install address, connect an iPhone, publish the first build.

## Quick start

```sh
scripts/build-core.sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate --spec project.yml
open RemoteDebug.xcodeproj
```

1. Run the `RemoteDebugMac` scheme on the Mac and press **공유 시작** (Start sharing). Log in to Tailscale in the browser window it opens. MagicDNS and HTTPS certificates must be on for the tailnet.
2. Connect the iPhone with a cable and use **iPhone 앱 설치…** on the **기기** (Devices) screen, or run the `RemoteDebugPhone` scheme from Xcode. The VPN entitlement needs a paid Apple Developer Program team.
3. In the iPhone app, turn on the VPN and log in with the same Tailscale account as the Mac. Scan the pairing QR code from the Mac and approve the request on the Mac.
4. Drop an Xcode project on the Mac window. Tap **설치** on the iPhone.

The build scripts call `eyebuild`; without it, create the [stand-in script](docs/setup.md#eyebuild가-없는-mac) first. Tailnet policy, signing, and troubleshooting are in [setup](docs/setup.md).

## Two iPhone apps: RemoteDebug and RD VPN

Install two apps on the iPhone. Both can run the same VPN and appear as the same tailnet device (the Tailscale state lives in a shared App Group).

- **RemoteDebug**: installs builds, receives files, collects crashes and feedback. It can also run the VPN.
- **RD VPN** (scheme `RemoteDebugVPN`): only runs the VPN. While it holds the VPN, updating RemoteDebug does not drop the connection, so the update installs inside the app without the official Tailscale app.

iOS runs one VPN at a time. When one app turns its VPN on the other one stops, and the Mac pairing stays because the device identity is the same.

- RemoteDebug's VPN app section moves the VPN to RD VPN or takes it back. The button opens the other app, which switches the VPN and returns.
- Updating RemoteDebug: if RD VPN holds the VPN, the update button installs right away. Otherwise the button moves the VPN first.
- Updating RD VPN: take the VPN over in RemoteDebug, then install RD VPN from the build list.
- First install: update RemoteDebug, install RD VPN, then use RD VPN's button that fetches the device identity from RemoteDebug. The existing identity moves to the shared storage and the Mac pairing is kept.

Switching between the two apps has not been verified on a real iPhone yet.

## Crashes and feedback from your apps

Problems in apps installed through RemoteDebug show up on the Mac, in the Mac app's crash and feedback screen and in the agent tool `remotedebug_crash_logs`.

- RemoteDebug iPhone app: after an abnormal exit it sends the record on the next launch. Settings has a form for sending feedback about RemoteDebug.
- Your app: add this repository (`https://github.com/oozoofrog/remotedebug`) as a Swift package and link `RemoteDebugFeedback`. The Mac app's project screen shows the code with the Mac address filled in.

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

"Confirmed" means only the scope written in the row. Real-device checks used one iPhone (iOS 27.2) on 2026-11-12.

| Scope | Status | How to reproduce |
| --- | --- | --- |
| Go core: pairing, sessions, IPA serving over a fake tailnet (`testcontrol`) | Confirmed | `scripts/go.sh test -race -count=1 ./...` |
| Go core tunnel mode: fake tailnet and in-memory TUN | Confirmed | `scripts/go.sh test -race -count=1 -run TestTunnel -v ./...` |
| `RDCore.xcframework` (macOS, iOS, iOS simulator; arm64) | Confirmed | `scripts/build-core.sh` |
| Debug build checks and IPA packaging: unit tests, fixtures, real Debug builds of the author's machine | Confirmed | `swift test --package-path Packages/RemoteDebugKit`, `scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh` |
| Mac host: real Go core with a fake tailnet, app launch and quit | Confirmed | `RD_TEST_TMPDIR=<writable folder> swift test --package-path Packages/MacHost`, `RD_E2E_APP=1 scripts/e2e-mac.sh` |
| iPhone logic and app: unit tests, simulator build and tests, unsigned device compile | Confirmed | `swift test --package-path Packages/PhoneClient`, [xcodebuild commands](docs/setup.md#명령줄-빌드와-시험) |
| Mac and iPhone logic together over a fake tailnet: pairing, list, install session, device removal | Confirmed | `scripts/e2e-full.sh` |
| Project connection logic (finding projects, schemes, fake builder, DerivedData suggestions, agent commands, skill and `AGENTS.md`) | Confirmed | `RD_TEST_TMPDIR=<writable folder> swift test --package-path Packages/MacHost` |
| Real iPhone with the RemoteDebug app: embedded Tailscale login, VPN, pairing, build list, installing other apps (real TLS, `itms-services`), diagnostic logs, receiving files | Partly confirmed | Used by the author. A large file stopped when the app went to the background; the background download fix is not confirmed. Not every step of the [device test procedure](docs/device-test.md) |
| RemoteDebug app updating itself over its own VPN | Fails | iOS stops the tunnel during the install. Use the update page over the official Tailscale app |
| Installing the iPhone app from a page served through the official Tailscale app (`tailscale serve`) | Confirmed with an earlier hand-made page | No record of trying the current update page in the Mac app on a real iPhone |
| Mac app UI by hand: start sharing, pairing sheet, approving a request, network screen, install sheet | Partly confirmed | Window screenshots and accessibility clicks. VoiceOver, dark mode, Dynamic Type not checked |
| Real `xcodebuild` builds of other projects from the Mac app | Confirmed | Builds published by the author's agents |
| Xcode build detection and notification, menu-bar residency and login item, dropping on the Dock icon | Not confirmed | No procedure |
| Install web page: Go tests, `logic.js` in JavaScriptCore, WKWebView end-to-end over a fake tailnet | Confirmed | `scripts/go.sh test -race -count=1 ./...`, `swift test --package-path Packages/WebPage`, `scripts/e2e-web.sh` |
| Install web page in Safari on a real iPhone through the official Tailscale app | Not confirmed | [D14](docs/device-test.md#d14-설치-웹-페이지공식-tailscale-앱) |
| One-time Tailscale key in the pairing QR (OAuth client, real Tailscale API) | Not confirmed | Logic tested with a fake API |
| Mac app installing the iPhone app on a cabled iPhone | Not confirmed | Logic tested with fake tools; bundle IDs per prefix checked with `xcodebuild -showBuildSettings` |
| **다른 계정으로 로그인** (log in with another account) on a real iPhone | Not confirmed | Simulator tests of the reset option |
| Debug confirmation dialog | Not confirmed | [D13](docs/device-test.md#d13-debug-확인-대화상자) |
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
| Package | MacHost | `Packages/MacHost` | `MacHostKit` (logic), `MacHostCore` (Go core bridge), `MacHostUI` (screens and previews, no Go runtime) |
| Package | PhoneClient | `Packages/PhoneClient` | iPhone app logic `PhoneClientKit` |
| Package | RDCore | `Packages/RDCore` | `RDCore.xcframework` and the Swift bridge `RDCoreBridge` |
| Package | E2E | `Packages/E2E` | Integration tests of Mac and iPhone logic, browser engine tests of the install page. No product code |
| Package | WebPage | `Packages/WebPage` | JavaScriptCore tests of the install page logic. No product code |
| Core | Go | `core/` | Tailscale node, host HTTP server, tunnel mode, update page, C API |
| Core | Install web page | `core/internal/host/web` | HTML, CSS, JS the Mac host serves at `/` (embedded in the core) |
| Scripts | | `scripts/` | Core build, tests, document checks |

| Document (Korean) | Contents |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Requirements, signing, building, first run, installing the iPhone app, pairing, files, updates, troubleshooting |
| [docs/device-test.md](docs/device-test.md) | Real-device test procedure |
| [docs/device-test-results.md](docs/device-test-results.md) | Real-device result sheet |
| [docs/protocol.md](docs/protocol.md) | Protocol v1 between the Mac, the iPhone, and the core |
| [docs/protocol-addenda.md](docs/protocol-addenda.md) | Rules that amend `docs/protocol.md`: install page (E), icons (F), logs (G), files (H), update page (I), Tailscale key in the pairing link (J) |
| [docs/tunnel.md](docs/tunnel.md) | iPhone packet tunnel |
| [docs/architecture.md](docs/architecture.md) | Structure and initial assumptions. Wrong sentences are listed in "Corrections to the documents" |
| [docs/appstore-review.md](docs/appstore-review.md) | App Store submission verdict |

When documents disagree, follow this order:

1. `docs/tunnel.md` replaces all of §6 of `docs/protocol.md`, the proxy parts of §9 (the sentence that `mode` is only `host`/`proxy`, and the iPhone's use of `rd_proxy_start`), and assumption A1 and the diagram of `docs/architecture.md`.
2. `docs/protocol-addenda.md` takes precedence over `docs/protocol.md` where the tunnel document is silent.
3. The rest of `docs/protocol.md` and `docs/architecture.md`, except what "Implementation that differs from the design documents" and "Corrections to the documents" below say.

## App Store verdict

Not submitted. The iPhone app asks iOS to install other apps (guideline 2.5.2); treated as a VPN app it carries the organization-account and disclosure duties of 5.4; and a reviewer cannot see the core feature without a Mac, a tailnet, and development provisioning. Approval is judged very unlikely. Submitting the Mac app alone is not recommended either (4.2.3(i), reviewer access). Recommended distribution is direct install from Xcode or Ad Hoc; TestFlight is not recommended. The verdict is an estimate based on this project's structure, not an Apple decision. Evidence and quotes are in the [verdict](docs/appstore-review.md).

## Known limitations

- Apple silicon only. Every slice of `RDCore.xcframework` is arm64.
- The VPN entitlement (Network Extension) needs a paid Apple Developer Program team for the iPhone app.
- iOS runs one VPN at a time. While the RemoteDebug VPN is on, the official Tailscale VPN is off, and the reverse.
- The RemoteDebug iPhone app cannot update itself over its own VPN. Use the update page through the official Tailscale app or install from the Mac with a cable.
- Nine on-device items of `docs/tunnel.md` remain unverified; they are U1–U9 in the [device test procedure](docs/device-test.md).
- Xcode canvas previews of the iPhone app fail on the author's machine with `Timed out waiting for signal to perform the initial JIT link`. The cause is unknown. Simulator runs and tests work.
- Mac app previews render, but scenarios that start sharing may show only a progress indicator.
- Restoring an iPhone from backup drops the tunnel state folder (it is excluded from backup), so Tailscale login and pairing must be redone. Not checked on a device ([D6](docs/device-test.md#d6-백업에서-복원)).
- The Mac also excludes its node state (`state`) and `identity.json` from Time Machine and migration. A restored or migrated Mac logs in again as a new node (`rd-mac-<new 8 chars>`) and every iPhone must pair again. Not checked with a real restore.
- A build whose Debug configuration cannot be proven by folder name or `*.debug.dylib` is published after you confirm it. Whether it changed after confirmation is compared by file metadata (path, kind, size, modification time, inode) for `.app` and by SHA-256 for `.ipa`. The `.app` comparison is not a content hash.
- After five wrong pairing codes the core discards the code, but `denied` events are limited to one per five seconds, so the Mac may keep showing the discarded code until the next event. Use **새 코드 만들기** (New code).
- If you quit the Mac app during an import, the import can still write after the storage lock is released. Wait for imports to finish before quitting and reopening.
- Neither app was checked with VoiceOver, dark mode, or Dynamic Type.
- The Mac app does not use App Sandbox. Its storage moved from the sandbox container to `~/Library/Application Support/RemoteDebug` with no migration.
- Project builds started by the Mac app do not pass `-allowProvisioningUpdates`; a project without a profile or with an unregistered device must be built once for device in Xcode. Installing the iPhone app itself does pass it.
- Xcode builds are found through DerivedData's `info.plist` (`WorkspacePath`) and Xcode's build location setting (default, or Custom > Relative to Workspace). Other build location settings are not found.
- Xcode build detection polls `Build/Products/Debug-iphoneos` and build records every three seconds, so it asks after the folder changes, not when the build starts.
- Any process of the same user can use the agent command (`~/Library/Application Support/RemoteDebug/agent/rd`), including approving pairing requests.
- The install web page approves a tailnet node, not a browser. Once approved, every app on that iPhone can reach the Mac. Remove the device on the Mac's **기기** screen to cut access.
- The install web page needs the official Tailscale VPN on the iPhone and HTTPS certificates in the tailnet. A tailnet policy that blocks the iPhone node from the Mac's port 443 blocks the page ([ACL notes](docs/setup.md#tailnet-정책acl)).
- Reloading the install web page does not resume watching an install in progress. The Mac's session expires on its own.

## Implementation that differs from the design documents

The numbers are line numbers in `.agent-loop/remotedebug-bridge/decisions.jsonl`.

| Design document | Current implementation | Evidence |
| --- | --- | --- |
| `docs/architecture.md` diagram and assumption A1: a local CONNECT proxy in the tunnel extension | A packet tunnel that relays IP packets to the tailnet ([`docs/tunnel.md`](docs/tunnel.md)). Apple TN3120 discourages listeners and proxies inside a packet tunnel | 5, 26 |
| `docs/protocol.md` §6: the iPhone sets per-host `allowedTargets` in the tunnel | None. A packet tunnel has no per-host allow list; a link to another Mac replaces the current one after confirmation | 20 |
| `docs/architecture.md:53`: screens in the Mac app target | Screens and previews are in `MacHostUI` (no Go runtime). The Go runtime in the app binary crashed Xcode previews | 33, 34, 41 |
| `docs/protocol.md` §5: storing allowed devices | Bound to the control server URL that approved them. Changing servers requires pairing again after confirmation | 34, 43 |
| `docs/protocol.md:3`: edit this document first when changing rules | Changed rules are in [`docs/protocol-addenda.md`](docs/protocol-addenda.md). When they differ, follow the addenda | 6 |
| `docs/architecture.md:5`: install only through Tailscale embedded in each app | The embedded path stays; an install web page for iPhones with only the official Tailscale app was added ([`docs/protocol-addenda.md`](docs/protocol-addenda.md) E) at the user's request | 61, 62, 63, 64, 65 |
| `docs/architecture.md:86`: Xcode and TestFlight internal distribution | Direct Xcode install or Ad Hoc. The [verdict](docs/appstore-review.md) does not recommend TestFlight (guideline 2.2) | 2 |
| `docs/appstore-review.md`, reading of 2.4.5: Mac app compatible with the sandbox, no launch at login | No App Sandbox; connected projects are built with `xcodebuild`; the app stays in the menu bar and can open at login. Requested by the user; the Mac App Store assessment does not reflect this | No record (user request, 2026-11-11) |
| `docs/architecture.md` assumption A3: Mac app with App Sandbox | The alternative in the same table ("switch to non-sandboxed distribution") was chosen | No record (user request, 2026-11-11) |

Current behavior not in the design documents:

- The iPhone tunnel sends only the tailnet suffix and reverse zones to `100.100.100.100`; it does not take over the device's DNS (19, 26).
- The team ID lives in `Config/Signing.local.xcconfig`, which `Config/Signing.xcconfig` includes, so it survives `xcodegen` (38, 39).
- Debug confirmation is bound to a metadata fingerprint of the bundle tree for `.app` (not a content hash) and to SHA-256 for `.ipa`. Bundle ID, version, and build number must also match (40, 43).
- State folders holding node keys are excluded from backup (31, 34, 35).
- A storage lock lets only one Mac app run at a time (34, 44).
- Logic lives in `MacHostKit` and `PhoneClientKit` so it is tested with `swift test` without signing (14, 15).
- Target settings are in `Apps/Mac/project-mac.yml` and `Apps/iOS/project-ios.yml`, included by the root `project.yml` (25).
- The Mac app builds only for `ARCHS=arm64` (10).
- Integration tests are `Packages/E2E` and `scripts/e2e-full.sh` (29, 46).

## Corrections to the documents

These sentences differ from the implementation. The documents were not edited; follow the right column.

| Location | Sentence in the document | Correct content |
| --- | --- | --- |
| `docs/architecture.md:84` | "iOS itself does not accept OTA installs of distribution-signed IPAs" | iOS installs Ad Hoc and Enterprise IPAs over the air too. Debug-only is enforced by the Mac app's checks (development profile, `get-task-allow`, Debug configuration) and the core's re-check at publish time (`debug`, `getTaskAllow`, size, SHA-256) |
| `docs/architecture.md:85` | "Secrets (auth keys) are stored only in the Keychain" | Tailscale auth keys are not stored; an entered key is passed to the core for the next start only. The optional Tailscale OAuth client is stored in the Mac Keychain. Node state (node key) stays in `stateDir`, which is excluded from backup |
| `docs/protocol.md:11` | Client: "the iPhone app, calling the host from a tsnet node inside the packet tunnel extension" | The client is the iPhone app or the install web page opened in Safari (`platform` value `Web`) |
| `docs/protocol.md:17` | "Node names are `rd-mac-<id8>` and `rd-phone-<id8>`." | Only for RemoteDebug app nodes. An iPhone paired through the install web page uses the official Tailscale app's node name |
| `docs/protocol.md:376` | "Allowing only `tcp:443` with tailnet ACL tags (`tag:rd-mac`, `tag:rd-phone`) adds a network-layer barrier" | With only these tag rules, an iPhone on the official Tailscale app (a user node without `tag:rd-phone`) cannot reach the Mac. Follow the [ACL notes](docs/setup.md#tailnet-정책acl) |

## Document check

The script prints its usage in Korean:

```
사용: scripts/check-docs.sh [--help]   (RD_QUOTES_CACHE_DIR=<폴더>를 주면 Apple 원문 사본으로 인용을 검사한다)
```

It prints one line per mismatch and exits with code 1 when any of these differ from the repository: paths in code spans and code blocks (except json) under `scripts/`, `docs/`, `Packages/`, `Apps/`, `core/`, `Config/`, `.agent-loop/`, and root files such as `project.yml`; scripts named in the documents; target, scheme, module, and bundle ID names; U items and the on-device items of `docs/tunnel.md`; D items and the run-order table; relative links and `#` heading anchors; screen text written in bold or double quotes in the install web page procedures (`docs/setup.md` web page section, `docs/device-test.md` D14), compared with the page source `core/internal/host/web` and the Mac app source `Packages/MacHost/Sources`. It also fails when a required document, `scripts/check_quotes.py`, or `scripts/check_protocol_examples.py` is missing. Paths in prose outside code spans are not checked. If Apple's original text cannot be downloaded, the quote check only warns.
