# Architecture (source of truth)

```
┌─────────────────┐  security find-generic-password   ┌───────────────────────────┐
│ CredentialStore │ ◀──────────────────────────────── │ login keychain            │
└────────┬────────┘  fallback ~/.claude/.credentials.json │ "Claude Code-credentials" │
         │ token (memory only)                        └───────────────────────────┘
         ▼
┌──────────────────┐  GET api.anthropic.com/api/oauth/usage
│     UsageAPI     │ ───────────────────────────────▶ GaugeSnapshot (Meter[])
└──────────────────┘
┌──────────────────┐  ~/.claude/projects/**/*.jsonl (incremental, offset per file)
│ TranscriptScanner│ ───────────────────────────────▶ TranscriptStats (+ JevWindow)
└──────────────────┘
┌──────────────────┐  rtk gain -d -f json (only if the binary exists)
│     RTKGain      │ ───────────────────────────────▶ RTKStats
└──────────────────┘
         │                         ▲
         └─── UsageViewModel (@MainActor, 60 s timer) ───┘
                          │
                          ▼
             UsagePanelView (MenuBarExtra, .window style)
```

## Components

| Component | Role | Notes |
|---|---|---|
| `CredentialStore` | Reads the Claude Code OAuth access token | Keychain via `/usr/bin/security` (same tool Claude Code writes with, so no extra ACL prompt); honours `CLAUDE_CONFIG_DIR`; rejects expired tokens and never refreshes them |
| `UsageAPI` | Calls the OAuth usage endpoint, parses generically | Any top-level object carrying `utilization` becomes a `Meter`: `five_hour` → session, `seven_day` → all, `seven_day_<x>` → model `x`; `extra_usage` is skipped |
| `TranscriptScanner` | Actor; exact token counts and Jev notices from transcripts | Per-file byte offset, only complete lines consumed, assistant messages de-duplicated by `message.id` (one message spans several JSONL lines), entries older than the week window pruned, files untouched since the window start skipped |
| `RTKGain` | Probes known prefixes for `rtk`, runs `gain -d -f json`, folds the daily rows into today / week / all time | Runs detached at utility priority; the block hides when `rtk` is absent. RTK only reports whole days, so a weekly window starting mid-day counts that whole day |
| `JevDetector` + scanner | Detects `~/.claude/plugins/cache/fast-jev-compaction`; the scanner parses `type: system` notices `fast-jev-compaction: kept K/M messages … (P% reduction …)` and `fallback to built-in summary` | De-duplicated by timestamp + text (the hook logs and toasts the same line); `decisions:` lines are ignored |
| `UsageMath` / `PaceProjection` | Landing %, needed vs. running %/h, even daily share | Window start = `resets_at − windowHours`. `isMeaningful` refuses to project before 30 minutes and 5% of the window have elapsed |
| `UsageViewModel` | Orchestrates refresh, exposes state, launch at login (`SMAppService`) | One instance only. Timers run in the run loop's `.common` mode, without which they stop while the popover is open. Tokens recount every 60 s; the gauge is called at most every 3 minutes, with exponential backoff to 15 minutes after a 429, keeping the last good reading |
| `MenuBarMeter` | Which meter the menu bar shows: `week` or `session`, stored under `menubar.meter` | A `@Published` with a `didSet`, never `@AppStorage`: that is a `DynamicProperty` refreshed only while a view graph is evaluated, so inside an `ObservableObject` it reads once and never publishes, and the title would silently stop following the setting |
| `UpdaterController` | Sparkle 2 auto-update: daily background check, never downloads or installs without consent | ClaudeMenu is `LSUIElement`, so it never becomes the active application and Sparkle's windows would open behind everything. A user-initiated check raises the activation policy to `.regular` for the session and lowers it back after. A **scheduled** find shows nothing and raises nothing: it surfaces an "Installer la version X" row in the panel, so a background check cannot steal focus |
| `UsagePanelView` | The panel, 340pt wide, height following the open sections | Hero (weekly %, reset countdown, segmented bar, pace sentence), budget card, three `DisclosureCard` sections (Anthropic limits per model, tokens consumed, tool savings), settings card (refresh / launch at login / quit) |
| `Theme` + `DisclosureCard` / `InfoRow` / `ActionRow` / `SegmentedBar` | Juicy-like building blocks | `DisclosureCard` is named so it never shadows `SwiftUI.Section`; open/closed state persists through `@AppStorage` |

## Decisions

- **No token refresh**: refreshing would mean writing the new token back to the keychain,
  racing with Claude Code. An expired token surfaces as an error card asking to run `claude`.
- **No sandbox**: the app reads `~/.claude` and runs `security`; it ships outside the App
  Store with Developer ID and notarization.
- **Generic meter parsing**: Anthropic adds per-model keys over time (`seven_day_opus`,
  `seven_day_sonnet`, others); the panel lists whatever comes back and prettifies the name.
- **French UI** (2026-09-21, Vincent's request): the panel speaks French throughout and uses
  French number formatting (`FR` helpers: decimal comma, `4 j 4 h` durations, `12,5 %`).
- **Native material, not a painted dark theme**: no background fill, no forced colour scheme,
  so the `MenuBarExtra` window shows the system material and follows light and dark. Cards are
  `Color.primary` opacities.
- **Height**: collapsible sections let the popover size to its content, capped at the usable
  screen height (`visibleFrame.height - 24`) and scrolling past it. Measured against the fixed
  gauge: 577pt all collapsed, 889pt in the default state, 1369pt with every section open. A hardcoded ceiling is a bug: 640pt clipped the default panel.
- **`UsagePanelView(scrolls:)`**: the popover scrolls, but `ImageRenderer` does not lay out a
  `ScrollView`, so the snapshot mode renders the same content without that container.
- **The scroll view's height is concrete, never inferred**: a `ScrollView` has no intrinsic
  height, and in a `MenuBarExtra` window that collapses the popover to a few points. `PanelSizer`
  measures a non-scrolling copy with `NSHostingController.preferredContentSize`, and the panel
  re-measures whenever `layoutSignature` changes.

## Updates

Sparkle 2, wired as a Swift Package. The feed is `appcast.xml` at the repo root, served over
`raw.githubusercontent.com`: no build step and no propagation delay, unlike the Pages site.

`sparkle:version` carries `CFBundleVersion`, which `Scripts/release.sh` derives from the commit
count, and `sparkle:shortVersionString` carries the marketing version. Sparkle compares that
integer against the running app, so putting `1.0.0` in `sparkle:version` would read as lower
than a build number and no update would ever be offered.

Updates are EdDSA-signed with the private key held in the login keychain under the account
`ClaudeMenu`; its public half is embedded as `SUPublicEDKey`. That key must never be
regenerated: every installed copy would reject all future updates.

## Development modes

| Environment variable | Effect |
|---|---|
| `CLAUDEMENU_DEBUG_WINDOW=1` | Also opens the panel in a regular window, sized to the panel's own fitting size |
| `CLAUDEMENU_SNAPSHOT=<path.png>` | Renders the panel off screen with `ImageRenderer`, writes the PNG and quits. Reads nothing from the screen, so it is safe during a call or a screen share |
| `CLAUDEMENU_SNAPSHOT_DARK=1` | Renders that snapshot in dark mode |
| `CLAUDEMENU_MEASURE=1` | Prints the size the popover would ask for, then quits. The only reliable check of the panel's height |
| `CLAUDEMENU_MEASURE_PLAIN=1` | With the above, measures the content without its scroll container |
| `CLAUDEMENU_FIXTURE=1` | Debug-only fixed gauge: deterministic layout measurements with no API call |
| `CLAUDEMENU_TIMERTEST=1` | Fires a scheduled timer and the app's own timer in each run loop mode and reports the counts, then quits |

## Build & release

XcodeGen (`project.yml`) → `ClaudeMenu.xcodeproj`. `Scripts/release.sh <version>` builds,
signs (Developer ID, hardened runtime), creates `release/ClaudeMenu-<version>.dmg`,
notarizes with the shared `AppliMacVincentGithub` profile and staples.
