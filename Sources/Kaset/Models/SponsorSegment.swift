import Foundation
import SwiftUI

/// A SponsorBlock segment, bridged from the WebView JavaScript.
struct SponsorSegment: Equatable, Sendable {
    let start: Double
    let end: Double
    let category: String

    /// SponsorBlock brand teal-green: #00a884
    static let brandColor = Color(red: 0, green: 0.66, blue: 0.52)

    /// The default SponsorBlock timeline color for this segment category.
    var color: Color {
        Self.color(for: self.category)
    }

    /// User-facing name for this segment category.
    var localizedCategoryName: String {
        Self.localizedName(for: self.category)
    }

    /// Matches SponsorBlock's default category palette so categories remain
    /// recognizable between Kaset and the browser extension.
    static func color(for category: String) -> Color {
        switch category {
        case "sponsor":
            Color(red: 0, green: 0.83, blue: 0)
        case "selfpromo":
            Color(red: 1, green: 1, blue: 0)
        case "interaction":
            Color(red: 0.8, green: 0, blue: 1)
        case "intro":
            Color(red: 0, green: 1, blue: 1)
        case "outro":
            Color(red: 0.01, green: 0.01, blue: 0.93)
        case "preview":
            Color(red: 0, green: 0.56, blue: 0.84)
        case "music_offtopic":
            Color(red: 1, green: 0.6, blue: 0)
        case "filler":
            Color(red: 0.45, green: 0, blue: 1)
        default:
            Self.brandColor
        }
    }

    static func localizedName(for category: String) -> String {
        switch category {
        case "sponsor":
            String(localized: "Sponsor")
        case "selfpromo":
            String(localized: "Self-promotion")
        case "interaction":
            String(localized: "Interaction Reminder")
        case "intro":
            String(localized: "Intro")
        case "outro":
            String(localized: "Outro")
        case "preview":
            String(localized: "Preview / Recap")
        case "music_offtopic":
            String(localized: "Non-Music")
        case "filler":
            String(localized: "Filler")
        default:
            category
        }
    }
}

/// Transient notice shown after SponsorBlock automatically skips a segment.
struct SponsorSkipNotice: Equatable, Identifiable, Sendable {
    let id: UUID
    let segment: SponsorSegment

    init(segment: SponsorSegment, id: UUID = UUID()) {
        self.id = id
        self.segment = segment
    }
}
