import SwiftUI

/// Settings for optional addons that extend the app with extra capabilities.
struct AddonsSettingsView: View {
    @State private var settings = SettingsManager.shared

    var body: some View {
        Form {
            // MARK: - Ad Blocker

            Section {
                Toggle("Enable Ad Blocker", isOn: self.$settings.adBlockEnabled)
                    .help("Blocks ad and tracking domains in all WebViews, and auto-skips YouTube in-video ads.")
            } header: {
                Text("Ad Blocker")
            } footer: {
                Text("Content-blocking rules block known ad-serving and tracking domains. YouTube video ads are intercepted at the API level before they load. Changes take effect after restarting Kaset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - SponsorBlock

            Section {
                Toggle("Enable SponsorBlock", isOn: self.$settings.sponsorBlockEnabled)
                    .help("Automatically skip sponsored segments and other non-content sections in YouTube videos.")

                if self.settings.sponsorBlockEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Skip these segment types:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(SettingsManager.sponsorBlockCategoryOptions, id: \.id) { category in
                            Toggle(category.label, isOn: Binding(
                                get: { self.settings.sponsorBlockCategories.contains(category.id) },
                                set: { enabled in
                                    if enabled {
                                        if !self.settings.sponsorBlockCategories.contains(category.id) {
                                            self.settings.sponsorBlockCategories.append(category.id)
                                        }
                                    } else {
                                        self.settings.sponsorBlockCategories.removeAll { $0 == category.id }
                                    }
                                }
                            ))
                        }
                    }
                }
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Powered by the SponsorBlock database. Segments are crowd-sourced — some videos may not have any. Settings take effect on the next video you watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Return YouTube Dislikes

            Section {
                Toggle("Enable Return YouTube Dislikes", isOn: self.$settings.returnYouTubeDislikesEnabled)
                    .help("Show dislike counts on YouTube videos, powered by the Return YouTube Dislikes API.")
            } header: {
                Text("Return YouTube Dislikes")
            } footer: {
                Text("Shows the dislike count next to the dislike button in the YouTube player bar. Data is fetched from the community-driven RYD API. Takes effect on the next video you watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - DeArrow

            Section {
                Toggle("Enable DeArrow", isOn: self.$settings.dearrowEnabled)
                    .help("Replace clickbait YouTube video titles with community-submitted accurate titles.")
            } header: {
                Text("DeArrow")
            } footer: {
                Text("Clickbait titles are replaced with accurate descriptions from the DeArrow community database. A toggle icon (↔) appears next to the title — click it to see the original. Powered by the same community as SponsorBlock. Takes effect on the next video you watch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
