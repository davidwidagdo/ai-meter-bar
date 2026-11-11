<h1 align="center">AI Meter Bar</h1>

<p align="center">AI quota, Claude profiles, network meters and captive-portal sign-in, in the macOS menu bar.</p>

<p align="center">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white">
  <img alt="AppKit" src="https://img.shields.io/badge/AppKit-menu_bar-147EFB?logo=apple&logoColor=white">
</p>

<p align="center">
  <img alt="The popover with sample data: Wi-Fi status, four Claude profiles with quota bars, Codex, Antigravity, CPU and RAM" src="docs/screenshot.jpg" width="380">
</p>

## Features

- **AI quota.** 5-hour and weekly quota per Claude account, whatever the profile is called, plus live Codex and Antigravity quota. Every reading shows its age, and the menu bar marks each value with its tool.
- **Claude profiles.** Open any profile in one click, create one with its own launcher and no Automator step, or move one to the Trash.
- **Other tools.** OpenCode, GitHub Copilot and Cursor show when they were last active, and appear when used in the last 30 days.
- **Portal sign-in.** Signs in within seconds after a network change or wake.
- **VPN.** Connect or disconnect each VPN account from the panel, without opening the VPN app. The VPN app keeps its profiles and passwords.
- **Meters.** Speed, today's usage, 30-day history, CPU, RAM and memory pressure.
- **Light.** Live numbers are read at launch and when you open the panel, nothing stays running for them, and nothing is drawn while the screen sleeps.

## How it works

Claude's numbers come from a file Claude keeps. Codex and Antigravity answer live at launch and when the panel opens, and their files are the fallback:

```mermaid
flowchart LR
  A[Claude usage files] --> M[Newest reading per account] --> E[Age rules]
  P[Launch or panel opens] --> B[Codex's own tool] --> E
  P --> G[Antigravity's local server] --> E
  C[File dates of other tools] --> E
  E --> F[Menu bar and popover]
```

Portal sign-in sends the password only after every check passes:

```mermaid
flowchart TD
  T[Network change, wake or poll] --> P{Internet works?}
  P -->|yes| C[Connected]
  P -->|no| G{Your portal's page?}
  G -->|no| I[Idle, nothing sent]
  G -->|yes| H{Form posts to your<br/>portal or gateway?}
  H -->|no| I
  H -->|yes| L[POST username and<br/>Keychain password]
  L --> R{Session live?}
  R -->|yes| OK[Connected]
  R -->|portal still asks| W[Wait 1, 5, then 15 minutes]
  R -->|no evidence| U[Check again]
```

## Getting started

Requires macOS 26+ on Apple Silicon and the Xcode Command Line Tools. There are no third-party dependencies.

```sh
cd macos-app
./build.sh --install
open "/Applications/AI Meter Bar.app"
```

Click the gauge in the menu bar. For portal sign-in, open **Settings**, choose **Portal**, and enter the username, password and Login URL.

## Settings

| Tab | What it holds |
| --- | --- |
| **Accounts** | Quota as left or used, profile names and colors, what appears, launchers, which VPNs appear |
| **Portal** | Auto-login, sign-in details, portal marker, and **Diagnose**, which checks the values as typed and sends nothing |
| **General** | Menu bar content, update intervals, units, Wi-Fi interface, start at login |

## Scripts

| Command | What it does |
| --- | --- |
| `macos-app/build.sh` | Builds the app and a `.dmg`; `--no-dmg` skips the image, `--install` copies the app to `/Applications` |
| `macos-app/Tests/run.sh` | Unit tests |
| `macos-app/make-appicon.swift` | Regenerates the app icon |
| `discover-portal.sh` | Shows a portal's login form when the app cannot read it |

## Security

- The password lives only in the Keychain, and logs never contain it, the portal address or an IP.
- The bar holds no AI login. Codex's own tool does its own sign-in and ends right after answering, and Antigravity is asked only on this Mac's loopback address.
- It is sent only to the Login URL's address, or to the Wi-Fi gateway once your portal marker matches. Anything else is refused.
- Portals use plain HTTP, so sign in only on networks you trust.

## Limits

- Claude's usage is only as fresh as Claude's last save, which is why every row shows its age. Claude pauses its own check when its menu bar menu has not been used for 24 hours, so use **Refresh** there.
- Antigravity's quota needs the app to be open, and its local server is not a public interface, so an update could change it.
- An account that reports only a weekly value shows **No 5h**.
- Separate profiles rely on Claude's `--user-data-dir` option, which an update could change.
- VPN control lists only VPNs macOS knows, those under System Settings, VPN. OpenVPN Connect is there from version 3.9; older versions do not show.
- MikroTik CHAP portals are not supported. **Diagnose** tells you if a page looks like one.
- Builds are ad-hoc signed unless you set `CODESIGN_IDENTITY`, so each rebuild asks once for Keychain access.

More detail for developers is in [macos-app/README.md](macos-app/README.md).

## Credits

Tool marks come from [Lobe Icons](https://github.com/lobehub/lobe-icons) 1.98.0 (MIT). The trademarks belong to their owners, and the marks only identify each tool.

## Author

Built by [David Immanuel Widagdo](https://github.com/davidwidagdo). Licensed under [MIT](LICENSE).
