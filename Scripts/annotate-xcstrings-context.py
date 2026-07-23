#!/usr/bin/env python3
"""Annotate Localizable.xcstrings with translator "context" comments.

Crowdin surfaces each string's `comment` field to translators as "Context".
Most of our strings had none, so translators had to guess where a word appears
(this is how "Subscribed" became the paid-subscription "Abbonato" instead of the
YouTube channel-follow "Iscritto" in Italian).

This script grounds every string's context in the REAL code that uses it: it
scans the Swift sources for each catalog key, finds the file(s) it appears in,
and writes a context sentence describing where in the app that surface lives and
what it is. Ambiguous or interpolated strings get a hand-written override.

It only FILLS EMPTY comments by default (existing comments — e.g. from source
`comment:` arguments — are kept). Re-run it after adding strings; pass
--overwrite to rewrite every generated comment.

The writer reproduces Xcode's exact `.xcstrings` formatting (2-space indent,
"key" : value, no trailing newline, alphabetically sorted keys), so the diff is
limited to the comment lines it adds.

Usage:
    python3 Scripts/annotate-xcstrings-context.py [--overwrite] [--check]
"""

from __future__ import annotations

import json
import os
import re
import sys

CATALOG = "Sources/Kaset/Resources/Localizable.xcstrings"
SOURCES = "Sources"

# A short marker so re-runs and reviewers can tell script-generated context apart
# from hand-authored source comments. Kept terse — Crowdin shows the whole line.
SUFFIX = ""  # (kept empty; context reads naturally without a tag)

# ---------------------------------------------------------------------------
# SURF: file basename -> the surface where its strings appear, and what it is.
# One sentence, translator-facing. This is the backbone: most strings get their
# context purely from the screen they live in plus their own English text.
# ---------------------------------------------------------------------------
SURF = {
    # --- Settings window (⌘,) tabs ---
    "GeneralSettingsView.swift": "Settings window → General tab (account, behavior, privacy, language, cache, updates, about).",
    "MusicSettingsView.swift": "Settings window → Music tab (YouTube Music playback and library options).",
    "YouTubeSettingsView.swift": "Settings window → YouTube tab (YouTube video playback, ambient backdrop, SponsorBlock/DeArrow).",
    "IntelligenceSettingsView.swift": "Settings window → Intelligence tab (on-device Apple Intelligence features: AI command bar, playlist refinement, lyrics explanations).",
    "EqualizerSettingsView.swift": "Settings window → Equalizer tab (system-audio graphic equalizer).",
    "ScrobblingSettingsView.swift": "Settings window → Scrobbling tab (Last.fm scrobbling).",
    "ExtensionsSettingsView.swift": "Settings window → Extensions/Add-ons tab.",
    "AddonsSettingsView.swift": "Settings window → Add-ons tab (optional bundled tools like yt-dlp).",

    # --- Equalizer engine (audio) ---
    "EQPreset.swift": "Equalizer preset name (graphic-EQ presets like Flat, Bass Boost, Vocal — shown in the Equalizer settings picker).",
    "EqualizerAudioEngine.swift": "Error message from the system-audio equalizer engine (audio capture/routing failures shown as an alert).",
    "EqualizerView.swift": "Equalizer panel UI (band sliders and controls).",
    "EqualizerService.swift": "Equalizer service status/error text.",

    # --- Bottom player bar & mini player ---
    "PlayerBar.swift": "Bottom playback bar of the YouTube Music player (play/pause, skip, shuffle, repeat, volume, track info).",
    "YouTubePlayerBar.swift": "Bottom playback bar of the YouTube video player (docked or overlaid on the video).",
    "MiniPlayerViews.swift": "Compact mini-player (small now-playing controls).",
    "PlayerBarProgressLane.swift": "Seek/progress lane in the bottom player bar.",

    # --- YouTube video (watch) page ---
    "YouTubeWatchView.swift": "YouTube video watch page (below the player: title, channel, subscribe/bell, description, chapters, comments, related).",
    "YouTubeWatchWebView+DocumentGeneration.swift": "YouTube video playback surface (WebView player) — internal/overlay labels.",
    "YouTubeShortsView.swift": "YouTube Shorts vertical player.",
    "ChannelNotificationPreference.swift": "Fallback labels for the YouTube channel notification 'bell' menu (All / Personalized / None).",

    # --- Queue ---
    "QueueView.swift": "Playback queue list.",
    "QueueSidePanelView.swift": "Queue side panel (Up Next).",
    "QueueSidePanelFooterActions.swift": "Action buttons at the bottom of the queue side panel (save as playlist, clear, etc.).",
    "QueueTableCellView.swift": "A single row in the playback queue.",
    "QueueSongMetadata.swift": "Queue row metadata text (title/artist).",

    # --- Library / browse / home ---
    "LibraryView.swift": "Your Library page (playlists, liked songs, subscribed podcasts — including empty states).",
    "HomeView.swift": "YouTube Music Home feed.",
    "HomeSection.swift": "Section header/label on the YouTube Music Home feed.",
    "ExploreView.swift": "YouTube Music Explore page.",
    "ChartsView.swift": "YouTube Music Charts page.",
    "NewReleasesView.swift": "YouTube Music New Releases page.",
    "MoodsAndGenresView.swift": "YouTube Music Moods & Genres page.",
    "MoodCategoryDetailView.swift": "A specific Mood/Genre category page.",
    "PodcastsView.swift": "Podcasts page.",
    "HistoryView.swift": "Listening history page (YouTube Music).",
    "TopSongsView.swift": "Artist 'top songs' list.",
    "FavoritesSection.swift": "Pinned/favorites section in the sidebar or home.",
    "FavoriteItem.swift": "A pinned favorite item (sidebar shortcut).",
    "FavoritesContextMenu.swift": "Right-click menu on a pinned favorite.",
    "FavoriteItem.swift": "A pinned favorite item's label.",

    # --- Search ---
    "SearchView.swift": "YouTube Music search page (search field, filters, results).",
    "SearchViewModel.swift": "Search results state text (YouTube Music).",
    "SearchAudit.swift": "Search result category/section labels (YouTube Music).",
    "SearchResponse.swift": "Search result section labels (YouTube Music).",
    "YouTubeSearchView.swift": "YouTube (video) search page.",
    "CommandBarView.swift": "AI command bar (⌘K natural-language control overlay).",

    # --- Artist / playlist detail ---
    "ArtistDetailView.swift": "Artist page (YouTube Music).",
    "ArtistDiscographyView.swift": "Artist discography list.",
    "ArtistEpisodesListView.swift": "Artist podcast-episodes list.",
    "ArtistParser.swift": "Artist page section labels (parsed from YouTube Music).",
    "ArtistSeeAllDestination.swift": "Artist 'see all' subpage title.",
    "PlaylistDetailView.swift": "Playlist page (track list and header).",
    "PlaylistDetailView+HeaderActions.swift": "Playlist page header action buttons (play, shuffle, save, etc.).",
    "PlaylistDetailView+RefineSheet.swift": "Playlist 'Refine with AI' sheet (Apple Intelligence playlist editing).",

    # --- YouTube browse surfaces ---
    "YouTubeContentView.swift": "YouTube (video) mode container / navigation.",
    "YouTubeHomeView.swift": "YouTube (video) Home feed.",
    "YouTubeHomeViewModel.swift": "YouTube (video) Home feed state text.",
    "YouTubeExploreView.swift": "YouTube (video) Explore page.",
    "YouTubeChannelView.swift": "YouTube channel page.",
    "YouTubeSubscriptionsView.swift": "YouTube Subscriptions feed.",
    "YouTubeHistoryView.swift": "YouTube watch-history page.",
    "YouTubePlaylistsView.swift": "YouTube playlists page.",
    "YouTubePlaylistDetailView.swift": "YouTube playlist page.",
    "YouTubeFeed.swift": "YouTube feed model labels (video/channel metadata).",
    "YouTubeFeedParser.swift": "YouTube feed section labels (parsed).",
    "YouTubeDownloadSheet.swift": "Video/audio download sheet (choose quality/format).",
    "YouTubeDownloadService.swift": "Download progress/error text.",
    "SponsorSegment.swift": "SponsorBlock segment category name (skippable segment type like Sponsor, Intro, Outro).",

    # --- Sidebar / navigation / accounts ---
    "Sidebar.swift": "Left sidebar navigation (YouTube Music).",
    "YouTubeSidebar.swift": "Left sidebar navigation (YouTube video mode).",
    "SidebarProfileView.swift": "Sidebar footer: account/profile area, plus Support, GitHub and 'Help translate' buttons.",
    "SidebarPinnedItem.swift": "A pinned item shown in the sidebar.",
    "SourceToggleView.swift": "Sidebar toggle that switches between YouTube Music and YouTube.",
    "AccountSwitcherPopover.swift": "Account switcher popover (choose Google/brand account).",
    "AccountRowView.swift": "A single account row in the account switcher.",
    "MainWindow.swift": "Main window chrome / top-level navigation.",

    # --- Onboarding / app-level / support ---
    "KasetApp.swift": "App-level UI: menu-bar commands, Settings tabs, and window titles.",
    "WhatsNewView.swift": "'What's New' release-notes sheet shown after an update.",
    "WhatsNewProvider.swift": "'What's New' release-notes entry text.",
    "SignInRequiredView.swift": "Sign-in-required prompt shown when an action needs a YouTube account.",
    "LoginSheet.swift": "Google sign-in sheet.",
    "SupportView.swift": "Support/tip page (Ko-fi supporter perks).",
    "CommunityView.swift": "Community page (supporter community feed).",
    "CommunityCompose.swift": "Community post composer.",
    "CommunityTabs.swift": "Community page tab labels.",
    "CommunityViewModel.swift": "Community page state text.",
    "UpdaterService.swift": "App auto-update (Sparkle) status/error text.",

    # --- Lyrics / intelligence ---
    "LyricsView.swift": "Lyrics panel.",
    "FoundationModelsService.swift": "On-device AI (Apple Intelligence) status/error text.",
    "CommandExecutor.swift": "Result/feedback text from an AI command bar action.",

    # --- Notifications / toasts / shared chrome ---
    "NotificationsInboxView.swift": "In-app notifications inbox.",
    "ToastView.swift": "Transient toast/banner message.",
    "ErrorView.swift": "Generic full-screen error state.",
    "CarouselShelf.swift": "Horizontal carousel shelf controls (scroll left/right, see all).",
    "InteractiveCardStyle.swift": "Interactive card accessibility label.",
    "ExplicitBadge.swift": "'Explicit' content badge on a track.",
    "AmbientBackdropStyle.swift": "Ambient backdrop style name (behind the YouTube video: Off / Static / Live).",
    "SongContextMenus.swift": "Right-click menu on a song (play next, add to queue/playlist, etc.).",
    "SongActionsHelper.swift": "Confirmation/feedback text for a song action.",
    "DiagnosticsLogger.swift": "Diagnostics/log label (developer-facing).",
    "SettingsManager.swift": "Setting option label (enum display name shown in Settings pickers).",
    "LegacyFallbackViews.swift": "macOS-15 fallback UI (shown when Liquid Glass is unavailable).",
    "MockUITestYTMusicClient.swift": "UI-test fixture label (not user-facing in production).",
    "YTMusicClient.swift": "YouTube Music API section label (parsed).",
    "main.swift": "Command-line/developer tool text (not in the app UI).",
}

# Short zone label per file, for joining multi-file (reused) strings.
ZONE = {
    "GeneralSettingsView.swift": "General settings",
    "MusicSettingsView.swift": "Music settings",
    "YouTubeSettingsView.swift": "YouTube settings",
    "IntelligenceSettingsView.swift": "Intelligence settings",
    "EqualizerSettingsView.swift": "Equalizer settings",
    "ScrobblingSettingsView.swift": "Scrobbling settings",
    "PlayerBar.swift": "the music player bar",
    "YouTubePlayerBar.swift": "the video player bar",
    "MiniPlayerViews.swift": "the mini player",
    "YouTubeWatchView.swift": "the YouTube video page",
    "YouTubeShortsView.swift": "YouTube Shorts",
    "QueueView.swift": "the queue",
    "QueueSidePanelView.swift": "the queue panel",
    "LibraryView.swift": "Your Library",
    "HomeView.swift": "the Home feed",
    "SearchView.swift": "search",
    "SearchAudit.swift": "search results",
    "SearchResponse.swift": "search results",
    "ArtistDetailView.swift": "the artist page",
    "PlaylistDetailView.swift": "the playlist page",
    "PlaylistDetailView+HeaderActions.swift": "the playlist page",
    "PodcastsView.swift": "Podcasts",
    "ChartsView.swift": "Charts",
    "ExploreView.swift": "Explore",
    "NewReleasesView.swift": "New Releases",
    "MoodsAndGenresView.swift": "Moods & Genres",
    "HistoryView.swift": "History",
    "Sidebar.swift": "the sidebar",
    "YouTubeSidebar.swift": "the sidebar",
    "KasetApp.swift": "the app menus",
    "LyricsView.swift": "the lyrics panel",
    "LegacyFallbackViews.swift": "the macOS-15 fallback UI",
    "CommunityView.swift": "Community",
    "CommunityCompose.swift": "the Community composer",
    "FavoritesSection.swift": "pinned favorites",
    "SongContextMenus.swift": "the song right-click menu",
}

# ---------------------------------------------------------------------------
# PER_KEY: exact, hand-written context for ambiguous or interpolated strings
# where the surface + English text isn't enough on its own.
# ---------------------------------------------------------------------------
PER_KEY = {
    # Subscribe / notifications — the ones that caused the it "Abbonato" bug.
    "Subscribe": "Button to subscribe to (follow) a YouTube channel or artist. NOT a paid subscription — the channel-follow sense (it: 'Iscriviti').",
    "Subscribed": "State of the Subscribe button once the user follows a YouTube channel/artist. NOT a paid subscription — the channel-follow sense (it: 'Iscritto').",
    "Unsubscribe": "Button to stop following a YouTube channel (it: 'Annulla iscrizione').",
    "Subscribe %@": "Button to subscribe to (follow) the YouTube channel named %@ (channel-follow, not a paid subscription).",
    "Notifications": "Title of the YouTube channel notification 'bell' menu (per-channel: All / Personalized / None).",
    "Collaborators": "Header of the picker for a YouTube video uploaded by multiple channels — lists each collaborating channel with its own Subscribe/bell.",
    "and": "Conjunction joining two collaborating YouTube channel names, e.g. 'Channel A and Channel B'.",
    "Notification settings": "Tooltip on the YouTube channel notification 'bell' button.",
    "Subscribe to podcasts on YouTube Music to see them here.": "Empty-state message on the Podcasts page when the user follows no podcasts.",
    "Save playlists and subscribe to podcasts on YouTube Music to see them here.": "Empty-state message in Your Library when it has no saved playlists or podcasts.",

    # Library empty states
    "No albums yet": "Empty-state title in Your Library's Albums section when the user has saved no albums.",
    "Save albums on YouTube Music to see them here.": "Empty-state subtitle in Your Library's Albums section (prompt to save albums).",
    "No liked songs yet": "Empty-state title in Your Library when the user has liked no songs.",
    "Songs you like will appear here": "Empty-state subtitle in Your Library's liked-songs section.",
    "Loading liked songs...": "Loading placeholder for the liked-songs list.",
    "Your Library": "Sidebar/section title for the user's personal library.",
    "Quick Access": "Sidebar section header for pinned/quick shortcuts.",
    "Access your playlists and liked songs": "Subtitle prompting the user to sign in to reach their library.",

    # Onboarding / welcome
    "Welcome to KasetPlus": "Onboarding welcome-screen title.",
    "Built with SwiftUI for a true macOS experience": "Onboarding tagline.",
    "Native Interface": "Onboarding feature title (native macOS UI).",
    "Control playback with your keyboard": "Onboarding feature subtitle (media keys).",
    "Media Keys": "Onboarding feature title (keyboard media keys).",
    "Sign in with Google": "Button that starts Google sign-in.",
    'Note: If passkeys don\'t work, use "Try another way" to sign in with password.': "Hint shown on the Google sign-in sheet.",

    # AI / Intelligence
    "Ask AI (⌘K)": "Button/label that opens the AI command bar (keyboard shortcut Command-K).",
    "Clear AI Context": "Button in Intelligence settings that resets the on-device AI session.",
    "Clears the AI session state. Use this if responses seem off or stuck.": "Help text under the 'Clear AI Context' button in Intelligence settings.",
    "Could not create AI session": "Error when the on-device AI model fails to start.",
    "When enabled, you can use natural language commands, AI-powered playlist refinement, and lyrics explanations.": "Description of the Apple Intelligence master toggle in Intelligence settings.",
    'Open the command bar to control music with natural language. Try saying "play something chill" or "add jazz to queue".': "Help text for the AI command bar in Intelligence settings.",

    # Playback / background
    "Background Playback": "Setting title: keep audio playing when the window is closed.",
    "Keep listening even when the window is closed": "Help text for the Background Playback setting.",
    "Play All": "Button that plays every item in the current list.",
    "Play All": "Button that plays the whole list from the top.",
    "Video quality": "Label for the video-quality picker (YouTube playback).",
    "Closed captions": "Toggle/label for subtitles on the video player.",

    # Support / tip
    "Thanks for the tip — supporter perks are active until %arg.": "Confirmation on the Support page after a Ko-fi tip; %arg is the expiry date.",
    "Connected as %arg": "Status on a settings page showing the connected account name %arg (e.g. Last.fm).",

    # Equalizer audio errors (System Audio permission)
    "Couldn't capture KasetPlus's audio (status %arg). Check Screen & System Audio Recording permission in System Settings.": "Equalizer engine error alert; %arg is a status code.",
    "KasetPlus can't access its own audio output. Open System Settings → Privacy & Security → Screen & System Audio Recording and enable KasetPlus, then toggle the equalizer on again.": "Equalizer permission error alert.",
    "Couldn't route KasetPlus's audio into the equalizer engine.": "Equalizer engine error alert.",
    "Couldn't negotiate a compatible audio format with the output device.": "Equalizer engine error alert.",
    "Couldn't configure the audio unit (%lld).": "Equalizer engine error alert; %lld is an OSStatus code.",
    "Couldn't create the audio unit.": "Equalizer engine error alert.",
    "Couldn't install the audio I/O proc (%arg).": "Equalizer engine error alert; %arg is a status code.",
    "Couldn't install the audio render callback (%lld).": "Equalizer engine error alert; %lld is a status code.",
    "Audio engine failed to start: %arg": "Equalizer engine error alert; %arg is the reason.",

    # Ambient backdrop (developer/debug + description)
    "Ambient backdrop style (developer)": "Developer-only label for the ambient-backdrop style picker.",
    '"Live" shifts the colors as the video plays; the others stay constant': "Help text under the ambient-backdrop style picker (YouTube settings).",

    # Chapters / misc interpolated
    "Jump to chapter: %arg": "Accessibility label on a video chapter button; %arg is the chapter title.",
    "Watched %arg%%": "Progress badge on a video thumbnail; %arg is the watched percentage.",
    "Show all %arg": "Button to expand a section; %arg is the section name.",
    "Sign in to use %arg": "Prompt to sign in for a feature named %arg.",
    "Scroll %arg left": "Accessibility label for a carousel's left scroll button; %arg is the shelf name.",
    "Scroll %arg right": "Accessibility label for a carousel's right scroll button; %arg is the shelf name.",
    "Notifications, %arg unread": "Accessibility label for the notifications button; %arg is the unread count.",
    "Item %lld": "Generic numbered list-item placeholder; %lld is the index.",
    "Error: %arg": "Generic error line; %arg is the underlying message.",
    "%lld songs": "Count of songs; %lld is the number.",
    "%lld songs listened today": "Scrobble stat; %lld is the number of songs played today.",
    "%arg songs listened today": "Scrobble stat; %arg is the number of songs played today.",
    "Loading…": "Generic loading placeholder.",
    "%@ %@": "Joins two pieces of metadata (e.g. artist and album) with a space.",
    "%@, %@, %@": "Joins three metadata fields with commas (e.g. for an accessibility label).",
    "%lld": "Bare number placeholder.",
}


def humanize(basename: str) -> str:
    name = re.sub(r"\.swift$", "", basename)
    name = re.sub(r"\+.*$", "", name)  # drop +Extension suffix
    name = re.sub(r"(View|ViewModel|Service|Manager|Parser|Sheet|Popover)$", "", name)
    # split camelCase / acronyms
    words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).strip()
    return words or name


def fallback_surface(basename: str) -> str:
    human = humanize(basename)
    return f"Appears in the {human} screen of the app."


def zone_for(basename: str) -> str:
    return ZONE.get(basename) or f"the {humanize(basename)} screen"


def load_index(keys):
    swift = []
    for root, _, fs in os.walk(SOURCES):
        for f in fs:
            if f.endswith(".swift"):
                swift.append(os.path.join(root, f))
    texts = {f: open(f, encoding="utf-8", errors="ignore").read() for f in swift}
    idx = {}
    for k in keys:
        probe = '"' + k + '"'
        hits = [f for f, t in texts.items() if probe in t]
        if not hits:
            pref = re.split(r"%@|%lld|%d|\\\(", k)[0]
            if len(pref) >= 6:
                hits = [f for f, t in texts.items() if '"' + pref in t]
        idx[k] = sorted({os.path.basename(f) for f in hits})
    return idx


def context_for(key: str, files: list[str]) -> str:
    if key in PER_KEY:
        return PER_KEY[key]
    if len(files) == 1:
        return SURF.get(files[0]) or fallback_surface(files[0])
    if len(files) > 1:
        # Reused string: name the distinct zones it shows up in.
        zones = []
        for f in files:
            z = zone_for(f)
            if z not in zones:
                zones.append(z)
        if len(zones) <= 3:
            return "Reusable label shown in " + ", ".join(zones) + "."
        return "Reusable label/button shown across several screens (e.g. " + ", ".join(zones[:3]) + ")."
    # Unmatched and not in PER_KEY: honest generic.
    return "User-facing text shown in the app."


def dump_xcstrings(obj) -> str:
    # Reproduces Xcode's .xcstrings formatting exactly (verified byte-identical
    # on the untouched catalog): 2-space indent, "key" : value, non-ASCII
    # literal, alphabetically sorted keys, no trailing newline.
    return json.dumps(obj, indent=2, ensure_ascii=False, separators=(",", " : "), sort_keys=True)


def main():
    overwrite = "--overwrite" in sys.argv
    check = "--check" in sys.argv

    original = open(CATALOG, encoding="utf-8").read()
    data = json.loads(original)
    strings = data["strings"]
    keys = [k for k in strings if k]

    idx = load_index(keys)

    filled = 0
    kept = 0
    for k in keys:
        entry = strings[k]
        if entry.get("comment") and not overwrite:
            kept += 1
            continue
        entry["comment"] = context_for(k, idx.get(k, []))
        filled += 1

    updated = dump_xcstrings(data)

    if check:
        print(f"Would set {filled} comments, keep {kept} existing. "
              f"({len(keys)} strings total)")
        return

    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(updated)
    print(f"Set {filled} context comments, kept {kept} existing "
          f"({len(keys)} strings total).")


if __name__ == "__main__":
    main()
