<h1 align="center">AI Meter Bar</h1>

<p align="center">AI quota, Claude profiles, VPN, network meters and Wi-Fi portal sign-in, in the macOS menu bar.</p>

<p align="center">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white">
  <img alt="AppKit" src="https://img.shields.io/badge/AppKit-menu_bar-147EFB?logo=apple&logoColor=white">
</p>

<p align="center">
  <img alt="The panel with sample data: Wi-Fi status, two VPN rows with connect buttons, four Claude profiles with quota bars, other tools, CPU and RAM" src="docs/screenshot.jpg" width="380">
</p>

## Features

- **AI quota.** Claude's 5-hour and weekly quota per account, plus live Codex and Antigravity quota. Every number shows its age. OpenCode, GitHub Copilot and Cursor show when they were last used.
- **Claude profiles.** Open a profile in one click, create one with its own launcher, or move one to the Trash.
- **VPN.** Connect or disconnect each VPN with one click, without opening the VPN app. Hide the ones you do not need.
- **Portal sign-in.** Signs in to a Wi-Fi login page by itself after a network change or wake.
- **Meters.** Speed, today's usage, 30-day history, CPU, RAM and memory pressure.
- **Light.** Live AI numbers are read only at launch and when the panel opens, and no helper stays running.

## How it works

```mermaid
flowchart LR
  A[Claude usage files] --> P[Panel and menu bar]
  B[Codex and Antigravity, asked live] --> P
  V[VPNs in macOS settings] --> P
  N[Wi-Fi and system counters] --> P
  P -->|Connect or Disconnect| M[macOS starts or stops the VPN]
```

Portal sign-in sends the password only after every check passes:

```mermaid
flowchart TD
  T[Network change, wake or poll] --> P{Internet works?}
  P -->|yes| C[Connected]
  P -->|no| G{Your portal's page?}
  G -->|no| I[Nothing sent]
  G -->|yes| H{Form posts to your<br/>portal or gateway?}
  H -->|no| I
  H -->|yes| L[Send username and<br/>Keychain password]
  L --> R{Session live?}
  R -->|yes| C
  R -->|portal still asks| W[Wait 1, 5, then 15 minutes]
```

## Getting started

Requires macOS 26 or later on Apple Silicon and the Xcode Command Line Tools. There are no third-party dependencies.

```sh
cd macos-app
./build.sh --install
open "/Applications/AI Meter Bar.app"
```

1. Click the gauge in the menu bar to open the panel.
2. **Portal sign-in:** open **Settings**, then **Portal**, and enter the username, password and Login URL.
3. **VPN:** a VPN shows up once it is listed in System Settings, VPN. For OpenVPN Connect this needs version 3.9 or later. Hide any VPN in **Settings**, **Accounts**.

## Settings

| Tab | What it holds |
| --- | --- |
| **Accounts** | Quota as left or used, which profiles, tools and VPNs appear, profile names, colors and launchers |
| **Portal** | Auto-login, sign-in details, portal marker, and **Diagnose**, which checks the typed values and sends nothing |
| **General** | Menu bar content, update intervals, units, Wi-Fi interface, start at login, usage history |

## Scripts

| Command | What it does |
| --- | --- |
| `macos-app/build.sh` | Builds the app and a `.dmg`; `--no-dmg` skips the image, `--install` copies the app to `/Applications` |
| `macos-app/Tests/run.sh` | Unit tests |
| `macos-app/make-appicon.swift` | Regenerates the app icon |
| `discover-portal.sh` | Shows a portal's login form when the app cannot read it; copy `config.example` to `config` first |

## Security and privacy

- The portal password lives only in the Keychain, and goes only to the Login URL's address, or to the Wi-Fi gateway once your portal marker matches.
- Logs never contain a password, portal address, IP or VPN name.
- The bar holds no AI login. Codex's own tool signs itself in and ends after answering; Antigravity is asked only on this Mac's loopback address.
- The VPN app keeps its profiles and passwords. The bar stores only the IDs of VPNs you hide.
- Portals use plain HTTP, so sign in only on networks you trust.

## Limits

- Claude's usage is only as fresh as Claude's last save. When Claude pauses its own check, use **Refresh** in Claude's menu bar menu.
- Antigravity's quota needs Antigravity to be open. Its local server and Claude's `--user-data-dir` option are not public interfaces, so an update could change them.
- One VPN app runs one tunnel at a time, so connecting a second profile of the same app ends the first.
- MikroTik CHAP portals are not supported. **Diagnose** tells you if a page looks like one.
- Builds are ad-hoc signed unless you set `CODESIGN_IDENTITY`, so each rebuild asks once for Keychain access.

Developer notes: [macos-app/README.md](macos-app/README.md).

## Credits

Tool marks come from [Lobe Icons](https://github.com/lobehub/lobe-icons) 1.98.0 (MIT). The trademarks belong to their owners, and the marks only identify each tool.

## Author

Built by [David Immanuel Widagdo](https://github.com/davidwidagdo). Licensed under [MIT](LICENSE).
