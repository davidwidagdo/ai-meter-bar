# AI Meter Bar app

Developer notes. See the [main README](../README.md) for what the app does.

## Run modes

| Argument | What it does |
| --- | --- |
| `--dump-status` | Prints local AI readings as JSON with profile names masked, then exits. Touches neither the Keychain nor the portal |
| `--demo-data` | Runs with invented data and its own preferences. Writes nothing to real settings, profiles or the Keychain |

## Source map

| Area | Files |
| --- | --- |
| Portal sign-in | `PortalClient`, `LoginForm`, `LoginOutcome`, `LoginThrottle`, `PortalDiagnostics`, `Keychain` |
| Meters | `MeterClock`, `SpeedMonitor`, `SystemMonitor`, `UsageStore`, `UsageHistoryWindowController` |
| AI usage | `LocalUsageReaders`, `LiveUsage`, `UsageModels`, `AIUsageCoordinator` |
| Claude profiles | `ClaudeProfiles`, `ClaudeInstances`, `ClaudeLauncher`, `Monogram`, `NewProfileWindowController` |
| Interface | `StatusPopoverController`, `PopoverContentView`, `PopoverKit`, `ProviderMark`, `MenuBarRenderer`, `SettingsWindowController` |

## Behavior worth knowing

- **Panel grid.** `UI` holds the tile, row and action sizes, and every card's rows use them, so columns line up from the header to Recent Sessions.
- **Live numbers.** At launch and when the panel opens, at most every 30 seconds. Codex: runs `codex app-server` from a fixed path, asks for rate limits, and ends it. Antigravity: finds its `language_server`, takes the session value from that process's arguments, and posts to the loopback ports that process owns, with no redirects. The value is never stored or logged, and the account fields in the reply are not read.
- **Accounts.** Each usage sample names its account. Folders on one account show its newest reading, and the account ID is never shown or logged.
- **Move to Trash.** Settings, Accounts, the row's menu. Never Default or a running profile, and only a launcher this app built goes with it.
- **Auto-login off.** Nothing signs in by itself, so the panel offers Sign in Now whenever the Mac is offline.
- **Sign-in results.** A login only counts as failed when the portal still asks for credentials. No evidence, or a sleep during the check, means check again.
- **Sleep.** Automatic checks stop while the Mac sleeps, including dark wakes. Locking the screen does not stop them.
- **After a rejection.** Automatic attempts wait 1, 5, then 15 minutes, and each network keeps its own wait. Sign in Now and saving Settings clear it. Sign in Now during an automatic check runs right after that check.
- **Login URL.** Without one, a form goes only to the Wi-Fi gateway, and only once a Portal marker matches. One that points at this Mac is refused.
- **Portal marker.** Use text only your portal's page shows, or its domain. A value found in the app's own addresses, such as the Apple probe URL or `<gateway>/login`, is ignored, and **Diagnose** says so. It filters honest networks and is not proof of identity.
- **Form targets.** A form must post to the Login URL's scheme, host and port, or upgrade it to https. An unreadable target is refused.
- **Redirects.** Followed only over http and https. Loopback addresses are refused, but a name or LAN address that reaches this Mac is not detected.
- **VPNs.** With a Portal marker set and an http Login URL, the app reaches the portal through the Wi-Fi gateway, so a VPN that owns DNS cannot hide its name. The gateway's own `/login` page is tried first; otherwise the portal is reached by its name, and through the gateway only if the name does not answer. An https Login URL always uses the portal's own name, so TLS can check it.
- **Saving the password.** Replaces the Keychain item, so it always has this app's own access list, and puts the old value back if the save fails.
- **HTTP.** `NSAllowsArbitraryLoads` is on because portals and the connectivity probe use plain HTTP.
