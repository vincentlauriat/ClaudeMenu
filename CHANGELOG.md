# Changelog

All notable changes to ClaudeMenu are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- The panel no longer fails to open: the scroll view added to cap its height left the menu bar window 10 points tall. It now receives a concrete height and adapts to the open sections, capped so it always fits under the menu bar.

### Notes
- No tagged release yet: build from source, see the README.
- The app icon is still a generated placeholder.
