import SwiftUI

/// A SponsorBlock segment, bridged from the WebView JavaScript.
struct SponsorSegment: Equatable, Sendable {
    let start: Double
    let end: Double
    let category: String

    /// SponsorBlock brand teal-green: #00a884
    static let brandColor = Color(red: 0, green: 0.66, blue: 0.52)
}
