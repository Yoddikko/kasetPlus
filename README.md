# KasetPlus

Fork of [Kaset](https://github.com/sozercan/kaset) — a native macOS client for YouTube Music and YouTube, built with Swift and SwiftUI.

> For everything else about the original project, see the [upstream README](https://github.com/sozercan/kaset).

## KasetPlus Addons

Built-in addons configurable from **Settings → Addons**:

- **Ad Blocker** — API-level ad prevention (json-prune), WKContentRuleList domain blocking, YouTube ad auto-skip
- **SponsorBlock** — Auto-skip sponsored segments, localized toast (7 languages), green segment markers on the progress bar
- **Return YouTube Dislikes** — RYD API integration, dislike count displayed with like/dislike buttons under video metadata
- **DeArrow** — Clickbait titles replaced live across Home/Search/Watch; toggle icon (↔) to see the original

## Installation

Download the latest release from the [Releases](https://github.com/Yoddikko/kasetPlus/releases) page.

> **Note:** The app is not signed. Clear extended attributes with:
> ```bash
> xattr -cr /Applications/Kaset.app
> ```

## Disclaimer
KasetPlus is an unofficial fork and not affiliated with YouTube, Google Inc., or the original Kaset project.
