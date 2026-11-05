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
| AI usage | `LocalUsageReaders`, `UsageModels`, `AIUsageCoordinator` |
| Claude profiles | `ClaudeProfiles`, `ClaudeInstances`, `ClaudeLauncher`, `Monogram`, `NewProfileWindowController` |
| Interface | `StatusPopoverController`, `PopoverContentView`, `PopoverKit`, `ProviderMark`, `MenuBarRenderer`, `SettingsWindowController` |

## Behavior worth knowing

- **Accounts.** Each usage sample names its account. Folders on one account show its newest reading, and the account ID is never shown or logged.
- **Move to Trash.** Settings, Accounts, the row's menu. Never Default or a running profile, and only a launcher this app built goes with it.
- **Sign-in results. A login only counts as failed when the portal still asks for credentials. No evidence, or a sleep during the check, means check again.
- **Sleep.** Automatic checks stop while the Mac sleeps, including dark wakes. Locking the screen does not stop them.
- **After a rejection.** Automatic attempts wait 1, 5, then 15 minutes. Sign in Now and saving Settings clear the wait.
- **Login URL.** Without one, a form goes only to the Wi-Fi gateway, and only once a Portal marker matches.
- **Portal marker.** Use text only your portal's page shows, or its domain. A value found in the app's own addresses, such as the Apple probe URL or `<gateway>/login`, is ignored, and **Diagnose** says so. It filters honest networks and is not proof of identity.
- **Form targets.** A form must post to the Login URL's scheme, host and port, or upgrade it to https. An unreadable target is refused.
- **Redirects.** Followed only over http and https, and never to this Mac.
- **VPNs.** With a Portal marker set, the app reaches the portal through the Wi-Fi gateway, so a VPN that owns DNS cannot hide its name.
- **HTTP.** `NSAllowsArbitraryLoads` is on because portals and the connectivity probe use plain HTTP.
