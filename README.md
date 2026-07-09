# KasetPlus

Fork of [Kaset](https://github.com/sozercan/kaset) — a native macOS client for YouTube Music and YouTube, built with Swift and SwiftUI.

> For everything else about the original project, see the [upstream README](https://github.com/sozercan/kaset).

## KasetPlus Features

### YouTube Video Lyrics Search
While watching any YouTube video, toggle the lyrics section from the player bar (music.note.list icon) or the "Lyrics" button below the video title. Lyrics are fetched from **[LRCLib](https://lrclib.net)** — a free, open-source lyrics database — and displayed inline with editable search.

### Addons
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

## Upstream Sync

[View commits behind upstream](https://github.com/sozercan/kaset/compare/main...Yoddikko:kasetPlus:main)

## Disclaimer
KasetPlus is an unofficial fork and not affiliated with YouTube, Google Inc., or the original Kaset project.
