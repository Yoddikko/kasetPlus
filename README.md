<div align="center">

# KasetPlus

### A cleaner, smarter, and more capable YouTube experience for macOS.

[![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/built%20with-SwiftUI-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest Release](https://img.shields.io/github/v/release/Yoddikko/kasetPlus?label=release&color=blue)](https://github.com/Yoddikko/kasetPlus/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Yoddikko/kasetPlus/total?label=downloads)](https://github.com/Yoddikko/kasetPlus/releases)
[![Stars](https://img.shields.io/github/stars/Yoddikko/kasetPlus?style=flat&label=stars)](https://github.com/Yoddikko/kasetPlus/stargazers)

**Native SwiftUI • Built-in addons • On-device AI • Video downloads • Distraction-free playback**

[Download KasetPlus](https://github.com/Yoddikko/kasetPlus/releases/latest)
&nbsp;•&nbsp;
[Original Kaset](https://github.com/sozercan/kaset)
&nbsp;•&nbsp;
[Upstream comparison](https://github.com/sozercan/kaset/compare/main...Yoddikko:kasetPlus:main)

</div>

---

## Overview

**KasetPlus** is a feature-focused fork of [Kaset](https://github.com/sozercan/kaset), a native macOS client for YouTube Music and YouTube built with Swift and SwiftUI.

It extends the original project with built-in content-filtering addons, on-device video summaries, lyrics, downloads, playback controls, comment search, and a cleaner watch-page experience.

> [!NOTE]
> Documentation for the original application and its base functionality is available in the [upstream README](https://github.com/sozercan/kaset).

---

## Highlights

<table>
<tr>
<td width="50%" valign="top">

### ✨ On-device AI summaries

Generate a concise TL;DR, key points, and intended audience directly from a video's captions using Apple Intelligence.

</td>
<td width="50%" valign="top">

### 🧘 Distraction-free viewing

Hide comments and the related-videos rail for a cleaner, more focused watch page.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🧩 Built-in addons

Enable ad filtering, SponsorBlock, Return YouTube Dislike, and DeArrow directly from the app.

</td>
<td width="50%" valign="top">

### ⬇️ Video and audio downloads

Download videos, extract MP3 audio, select quality, estimate file size, and include subtitles.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🎵 Lyrics for YouTube videos

Search LRCLib and display editable lyrics inline while watching regular YouTube videos.

</td>
<td width="50%" valign="top">

### ⚡ Improved performance

General performance improvements for a faster and smoother application experience.

</td>
</tr>
</table>

---

## Built-in Addons

All addons can be configured from:

**`Settings` → `Addons`**

<table>
<thead>
<tr>
<th width="70">Icon</th>
<th width="190">Addon</th>
<th>Description</th>
</tr>
</thead>
<tbody>
<tr>
<td align="center">🛡️</td>
<td><strong>Ad Blocker</strong></td>
<td>
Combines API-level JSON pruning, <code>WKContentRuleList</code> domain filtering, and YouTube ad auto-skip.
</td>
</tr>
<tr>
<td align="center">
<a href="https://github.com/ajayyy/SponsorBlock">
<img src="https://raw.githubusercontent.com/ajayyy/SponsorBlock/master/public/icons/LogoSponsorBlocker256px.png" width="44" alt="SponsorBlock icon">
</a>
</td>
<td>
<strong><a href="https://github.com/ajayyy/SponsorBlock">SponsorBlock</a></strong>
</td>
<td>
Automatically skips known sponsored segments, displays localized toast notifications in seven languages, and adds green segment markers to the progress bar.
</td>
</tr>
<tr>
<td align="center">
<a href="https://github.com/Anarios/return-youtube-dislike">
<img src="https://raw.githubusercontent.com/Anarios/return-youtube-dislike/main/Extensions/combined/icons/icon128.png" width="44" alt="Return YouTube Dislike icon">
</a>
</td>
<td>
<strong><a href="https://github.com/Anarios/return-youtube-dislike">Return YouTube Dislike</a></strong>
</td>
<td>
Integrates with the RYD API and displays the dislike count alongside the like and dislike controls below the video metadata.
</td>
</tr>
<tr>
<td align="center">
<a href="https://github.com/ajayyy/DeArrow">
<img src="https://raw.githubusercontent.com/ajayyy/DeArrow/master/public/icons/logo.svg" width="44" alt="DeArrow icon">
</a>
</td>
<td>
<strong><a href="https://github.com/ajayyy/DeArrow">DeArrow</a></strong>
</td>
<td>
Replaces clickbait titles live across Home, Search, and Watch pages. Use the <strong>↔</strong> toggle to temporarily reveal the original title.
</td>
</tr>
</tbody>
</table>

---

## Features

### ✨ AI Video Summary

Open a video and select the **Summary** button next to **Lyrics** to generate:

- A concise TL;DR
- The video's key points
- A description of who the video is for

Summaries are generated locally on your Mac from the video's captions using Apple Intelligence Foundation Models. No API key is required, and the feature can work offline.

> [!IMPORTANT]
> AI Video Summary requires **macOS 26** with **Apple Intelligence** enabled. The Summary button is automatically hidden when the feature is unavailable.

---

### 🧘 Distraction-Free Watch Page

Enable:

**`Settings` → `YouTube` → `Distraction-Free Watch Page`**

This hides:

- The comments section
- The related-videos rail

The video player and its metadata remain visible.

---

### 🎵 YouTube Video Lyrics Search

Display lyrics while watching regular YouTube videos using either:

- The `music.note.list` control in the player bar
- The **Lyrics** button below the video title

Lyrics are fetched from [LRCLib](https://lrclib.net), a free and open-source lyrics database, and displayed inline with an editable search interface.

---

### ⬇️ YouTube Video Download

Use the download button in the player bar to:

- Download the current video
- Extract audio as MP3
- Choose the preferred quality
- View estimated download sizes
- Include available subtitles
- Write subtitles as `.srt`
- Embed captions into downloaded videos

Downloads are powered by a bundled copy of [yt-dlp](https://github.com/yt-dlp/yt-dlp), so no external installation is required.

Downloaded files are saved to:

```text
~/Downloads/KasetPlus/
