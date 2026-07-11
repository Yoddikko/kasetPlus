# KasetPlus

Fork of [Kaset](https://github.com/sozercan/kaset) — a native macOS client for YouTube Music and YouTube, built with Swift and SwiftUI.

> For everything else about the original project, see the [upstream README](https://github.com/sozercan/kaset).

### Addons
Built-in addons configurable from **Settings → Addons**:

- **Ad Blocker** — API-level ad prevention (json-prune), WKContentRuleList domain blocking, YouTube ad auto-skip
- **SponsorBlock** — Auto-skip sponsored segments, localized toast (7 languages), green segment markers on the progress bar
- **Return YouTube Dislikes** — RYD API integration, dislike count displayed with like/dislike buttons under video metadata
- **DeArrow** — Clickbait titles replaced live across Home/Search/Watch; toggle icon (↔) to see the original

## KasetPlus Features

### AI Video Summary
Open a video and hit the **Summary** (✨) button next to *Lyrics* to get a TL;DR, key points, and who the video is for — generated **entirely on-device** by Apple Intelligence (Foundation Models). Nothing leaves your Mac, no API key, works offline. Requires macOS 26 with Apple Intelligence; the button hides itself otherwise. Built from the video's captions.

### Distraction-Free Watch Page
Toggle **Settings → YouTube → Distraction-Free Watch Page** to hide the comments and the related-videos rail, leaving just the video and its metadata.

### Performance improvements
Improved app performance overall

### YouTube Video Lyrics Search
While watching any YouTube video, toggle the lyrics section from the player bar (music.note.list icon) or the "Lyrics" button below the video title. Lyrics are fetched from **[LRCLib](https://lrclib.net)** — a free, open-source lyrics database — and displayed inline with editable search.

### YouTube Video Download
Download any YouTube video (or extract audio as MP3) via the download button (↓) in the player bar. Quality picker with size estimates, and an **Include subtitles** option (writes `.srt` and embeds captions into videos). Bundled **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** — no external install needed. Files saved to `~/Downloads/KasetPlus/`.

### Playback Speed & Comment Search
Change playback speed (0.5x–2x) from the gear (⚙) menu in the player bar. Search through video comments with inline filtering below the video.

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
