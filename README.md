<h1 align="center"><img src="https://github.com/user-attachments/assets/c964b327-f5e2-4929-97df-0834926c944f" width="58" height="58" alt="KasetPlus icon">&nbsp;&nbsp;KasetPlus</h1>

<p align="center">
  <strong>A cleaner, smarter, and more capable YouTube experience for macOS.</strong>
</p>

<p align="center">
  <a href="https://www.apple.com/macos/">
    <img src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white" alt="macOS">
  </a>
  <a href="https://www.swift.org/">
    <img src="https://img.shields.io/badge/built%20with-SwiftUI-F05138?logo=swift&logoColor=white" alt="SwiftUI">
  </a>
  <a href="https://github.com/Yoddikko/kasetPlus/releases/latest">
    <img src="https://img.shields.io/github/v/release/Yoddikko/kasetPlus?label=release&color=007AFF" alt="Latest release">
  </a>
  <a href="https://github.com/Yoddikko/kasetPlus/releases">
    <img src="https://img.shields.io/github/downloads/Yoddikko/kasetPlus/total?label=downloads" alt="Downloads">
  </a>
  <a href="https://github.com/Yoddikko/kasetPlus/stargazers">
    <img src="https://img.shields.io/github/stars/Yoddikko/kasetPlus?style=flat&label=stars" alt="Stars">
  </a>
</p>

<p align="center">
  Native SwiftUI &nbsp;•&nbsp; Built-in addons &nbsp;•&nbsp; On-device AI<br>
  Video downloads &nbsp;•&nbsp; Lyrics &nbsp;•&nbsp; Distraction-free playback
</p>

<p align="center">
  <a href="https://github.com/Yoddikko/kasetPlus/releases/latest"><strong>Download KasetPlus</strong></a>
  &nbsp;•&nbsp;
  <a href="https://github.com/sozercan/kaset">Original Kaset</a>
  &nbsp;•&nbsp;
  <a href="https://github.com/sozercan/kaset/compare/main...Yoddikko:kasetPlus:main">Upstream comparison</a>
</p>

---

<p>
  ⭐️ Enjoying <strong>KasetPlus</strong>? If you find it useful, please consider
  giving the project a star! ❤️
</p>

<p>
  KasetPlus wouldn’t exist without the incredible work behind
  <a href="https://github.com/sozercan/kaset"><strong>Kaset</strong></a>.
  If you’re considering supporting development, please consider supporting
  the original project first.
</p>

<p>
  ☕ <a href="https://ko-fi.com/sozercan"><strong>Buy him a coffee</strong></a>
  and help support the project that made KasetPlus possible. 🙏
</p>

<p>
  You can also support the development of KasetPlus by
  <a href="https://ko-fi.com/yodddd">buying me a coffee</a>.
</p>

## Overview

**KasetPlus** is a feature-focused fork of [Kaset](https://github.com/sozercan/kaset), a native macOS client for YouTube Music and YouTube built with Swift and SwiftUI.

KasetPlus extends the original project with built-in content filtering, on-device video summaries, lyrics search, media downloads, additional playback controls, comment search, and a cleaner watch-page experience.

> [!NOTE]
> For information about the original application and its base functionality, see the [upstream README](https://github.com/sozercan/kaset).

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

Hide comments and the related-videos rail for a cleaner and more focused watch page.

</td>
</tr>

<tr>
<td width="50%" valign="top">

### 🧩 Built-in addons

Enable ad filtering, SponsorBlock, Return YouTube Dislike, and DeArrow directly from the application.

</td>
<td width="50%" valign="top">

### ⬇️ Video and audio downloads

Download videos, extract MP3 audio, choose the output quality, view size estimates, and include subtitles.

</td>
</tr>

<tr>
<td width="50%" valign="top">

### 🎵 Lyrics for YouTube videos

Search LRCLib and display editable lyrics inline while watching regular YouTube videos.

</td>
<td width="50%" valign="top">

### ⚡ Improved performance

General performance improvements provide a faster and smoother application experience.

</td>
</tr>
</table>

---

## Built-in Addons

Configure all addons from:

**`Settings` → `Addons`**

<table>
<thead>
<tr>
<th width="72">Icon</th>
<th width="210">Addon</th>
<th>Description</th>
</tr>
</thead>

<tbody>
<tr>
<td align="center">🛡️</td>
<td><strong>Ad Blocker</strong></td>
<td>
API-level JSON pruning, <code>WKContentRuleList</code> domain filtering, and automatic YouTube ad skipping.
</td>
</tr>

<tr>
<td align="center">
<a href="https://github.com/ajayyy/SponsorBlock">
<img src="https://raw.githubusercontent.com/ajayyy/SponsorBlock/master/public/icons/LogoSponsorBlocker256px.png" width="42" alt="SponsorBlock">
</a>
</td>
<td>
<strong>
<a href="https://github.com/ajayyy/SponsorBlock">SponsorBlock</a>
</strong>
</td>
<td>
Automatically skips sponsored segments, displays localized notifications, and adds green segment markers to the progress bar.
</td>
</tr>

<tr>
<td align="center">
<a href="https://github.com/Anarios/return-youtube-dislike">
<img src="https://raw.githubusercontent.com/Anarios/return-youtube-dislike/main/Extensions/combined/icons/icon128.png" width="42" alt="Return YouTube Dislike">
</a>
</td>
<td>
<strong>
<a href="https://github.com/Anarios/return-youtube-dislike">Return YouTube Dislike</a>
</strong>
</td>
<td>
Displays the estimated dislike count alongside the like and dislike controls below the video metadata.
</td>
</tr>

<tr>
<td align="center">
<a href="https://github.com/ajayyy/DeArrow">
<img src="https://raw.githubusercontent.com/ajayyy/DeArrow/master/public/icons/logo.svg" width="42" alt="DeArrow">
</a>
</td>
<td>
<strong>
<a href="https://github.com/ajayyy/DeArrow">DeArrow</a>
</strong>
</td>
<td>
Replaces clickbait titles across Home, Search, and Watch pages. Use the <strong>↔</strong> button to reveal the original title.
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

Summaries are generated on your Mac from the video's captions using Apple Intelligence Foundation Models.

No external API key is required.

> [!IMPORTANT]
> AI Video Summary requires **macOS 26** with **Apple Intelligence** enabled. The Summary button is hidden when the feature is unavailable.

---

### 🧘 Distraction-Free Watch Page

Enable the feature from:

**`Settings` → `YouTube` → `Distraction-Free Watch Page`**

The option hides:

- The comments section
- The related-videos rail

The video player and its metadata remain visible.

---

### 🎵 YouTube Video Lyrics Search

Display lyrics while watching YouTube videos using either:

- The lyrics control in the player bar
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
- Save subtitles as `.srt`
- Embed captions into downloaded videos

Downloads are powered by a bundled copy of [yt-dlp](https://github.com/yt-dlp/yt-dlp), so no external installation is required.

Downloaded files are saved to:

```text
~/Downloads/KasetPlus/
