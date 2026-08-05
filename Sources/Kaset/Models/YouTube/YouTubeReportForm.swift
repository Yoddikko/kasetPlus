import Foundation

/// The native "Report" (flag) form for a video.
///
/// YouTube's web report flow is a two-step InnerTube exchange:
///  1. `flag/get_form` (seeded with the video's report `params`, taken from the
///     overflow menu's FLAG entry) returns the list of reason options — each
///     reason carries its own opaque submit `params`.
///  2. `flag/flag` submits the chosen reason's `params`.
///
/// Both the reason labels and every submit token come straight from YouTube, so
/// submitting just replays YouTube's own endpoint; nothing here is fabricated.
struct YouTubeReportForm: Hashable {
    /// A single selectable reason from the report form.
    struct Reason: Hashable, Identifiable {
        /// Stable identifier for the reason, when YouTube provides one
        /// (falls back to the submit `params`, which is always unique).
        let id: String
        /// Localized label straight from YouTube (e.g. "Sexual content",
        /// "Violent or repulsive content", "Spam or misleading").
        let label: String
        /// Opaque params to POST to `flag/flag` to submit this reason.
        let submitParams: String
    }

    /// Localized form title from YouTube (e.g. "Report video"), when present.
    let title: String?
    /// The selectable reasons, in the order YouTube returned them.
    let reasons: [Reason]
}
