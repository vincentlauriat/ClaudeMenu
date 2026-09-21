# Changelog

All notable changes to ClaudeMenu are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-09-21

First public release, signed with a Developer ID certificate and notarised by Apple.

### Added
- Sparkle 2 auto-update. Later versions install from inside the app, from a "Rechercher des mises à jour" row in the settings card. Updates are EdDSA-signed; the app checks daily but never downloads or installs without consent.
- As an agent app with no Dock icon, ClaudeMenu raises itself to a regular, activatable application while Sparkle shows anything, and lowers itself back afterwards. Without that, update dialogs would open behind other windows with no way to reach them.

## [Unreleased]

### Changed
- Scheduled update checks use Sparkle's gentle reminders: a background find never opens a window and never raises the app, it surfaces an "Installer la version X" row in the panel instead. Sparkle still handles user-initiated checks itself, and the app raises its activation policy for those so the window is reachable.


### Added
- Menu bar item showing the weekly `all` percentage, and a panel with:
  - a hero card: weekly percentage, reset countdown, segmented bar, pace sentence;
  - a daily budget card: the even share of the remaining quota per remaining day;
  - **Limites Anthropic par modèle**: every meter the API reports (5-hour session, 7-day
    `all`, one per model), each with its reset time, current rate and sustainable rate;
  - **Tokens consommés**: replies, output tokens and context tokens read, today and this
    week, plus per-reply averages, counted off the local transcripts;
  - **Économies des outils**: RTK token savings and Jev compaction statistics, each block
    appearing only when the tool is installed.
- Launch at login, manual refresh, automatic refresh every minute.
- French interface with French number formatting.
- Development modes: `CLAUDEMENU_DEBUG_WINDOW=1` opens the panel in a regular window, and
  `CLAUDEMENU_SNAPSHOT=<path.png>` renders it off screen to a PNG without reading the screen.

### Fixed
- The panel no longer scrolls in its normal state: the height cap was a hardcoded 640pt while the default panel is 889pt tall, so the controls at the bottom were hidden. The cap now follows the usable screen height.
- The figures no longer freeze while the panel is open: the refresh timers ran in the run loop's default mode, which is suspended while a menu bar popover tracks events. Opening the panel now also refreshes it.
- The panel no longer fails to open: the scroll view added to cap its height left the menu bar window 10 points tall. It now receives a concrete height and adapts to the open sections, capped so it always fits under the menu bar.

### Notes
- No tagged release yet: build from source, see the README.
- The app icon is still a generated placeholder.
