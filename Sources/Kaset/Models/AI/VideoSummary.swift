import Foundation
import FoundationModels

/// AI-generated summary of a YouTube video, produced on-device from its
/// transcript with Foundation Models.
@available(macOS 26.0, *)
@Generable
struct VideoSummary {
    /// One or two sentences capturing the whole video.
    @Guide(description: "A 1-2 sentence TL;DR of what the video is about.")
    let tldr: String

    /// The main points, in the order they appear.
    @Guide(description: "3-6 concise key points or takeaways from the video, each a short phrase or sentence.")
    let keyPoints: [String]

    /// Who this video is for / what you get out of it.
    @Guide(description: "A short sentence on who would find this video useful or what the viewer gains.")
    let audience: String
}
