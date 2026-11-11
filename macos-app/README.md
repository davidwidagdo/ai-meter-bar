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
| VPN | `VPN` (list parser and row model), `VPNController` |
| Meters | `MeterClock`, `SpeedMonitor`, `SystemMonitor`, `UsageStore`, `UsageHistoryWindowController` |
| AI usage | `LocalUsageReaders`, `LiveUsage`, `UsageModels`, `AIUsageCoordinator` |
| Claude profiles | `ClaudeProfiles`, `ClaudeInstances`, `ClaudeLauncher`, `Monogram`, `NewProfileWindowController` |
| Interface | `StatusPopoverController`, `PopoverContentView`, `PopoverKit`, `ProviderMark`, `MenuBarRenderer`, `SettingsWindowController` |

## Behavior worth knowing

**Portal**
- **Gates.** The page must hold a login form, or the Portal marker when one is set. A form must post to the Login URL's scheme, host and port, or upgrade it to https. Without a Login URL, it goes only to the Wi-Fi gateway after the marker matches.
- **Marker.** Use text only your portal's page shows. A value found in the app's own addresses, such as the Apple probe URL or `<gateway>/login`, is ignored, and **Diagnose** says so.
- **VPN owns DNS.** With a marker and an http Login URL, the gateway's own `/login` page is tried first, then the portal's name, and the gateway again only if the name does not answer. An https Login URL always uses the portal's name, so TLS can check it.
- **Results.** A login fails only when the portal still asks for credentials. No evidence, or a sleep during the check, means check again.
- **After a rejection.** Automatic attempts wait 1, 5, then 15 minutes, per network. Sign in Now and saving Settings clear the wait.
- **Sleep.** Automatic checks stop while the Mac sleeps, including dark wakes.
- **Redirects.** Followed only over http and https, never to a loopback address.
- **Password.** Saving replaces the Keychain item, so it keeps this app's access list, and restores the old value if the save fails.
- **HTTP.** `NSAllowsArbitraryLoads` is on because portals and the connectivity probe use plain HTTP.

**AI usage**
- **Live numbers.** At launch and on panel open, at most every 30 seconds. Codex: `codex app-server` from a fixed path, asked for rate limits, then ended. Antigravity: its `language_server` on the loopback ports that process owns. Session values are never stored or logged.
- **Accounts.** Each Claude sample names its account; profiles on one account show its newest reading. The account ID is never shown or logged.

**VPN**
- **Listing.** `scutil --nc list` at launch, panel open, wake and Save. A failed listing keeps the last one. Status then comes from `SCNetworkConnection` events, with no polling.
- **Connect.** Lingers, so the VPN stays up when the bar quits. A connect waits 45 seconds; one that drops back shows as failed and offers the VPN's own app. Stop works while connecting.
- **Privacy.** No VPN profile, password, host or name is stored or logged. Only the IDs of hidden VPNs stay in the app's preferences.

**Interface**
- **Panel grid.** `UI` holds the tile, row and action sizes, so columns line up from the header to Recent Sessions.
- **Move to Trash.** Never Default or a running profile, and only a launcher this app built goes with it.
