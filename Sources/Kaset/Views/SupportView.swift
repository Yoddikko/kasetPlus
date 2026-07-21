import SwiftUI

// MARK: - SupportView

/// Sheet for supporting KasetPlus via Ko-fi. Mirrors the Community hub's sheet
/// chrome (fixed size, ultra-thick material, close button).
///
/// The supporter *status* shown here is driven by `SupportManager`, whose real
/// Ko-fi verification isn't wired yet — the DEBUG "Testing" section lets you
/// flip states to preview the UI.
struct SupportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var support = SupportManager.shared
    @State private var email = ""
    @State private var verifying = false
    @State private var verifyMessage: String?
    @State private var supporters: [SupportManager.Supporter] = []
    @State private var showAllSupporters = false

    private static let accent = Color(red: 1.0, green: 0.30, blue: 0.45)
    private static let supporterPreviewCount = 8

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                self.hero

                if self.support.isSupporter {
                    self.supporterCard
                } else {
                    self.supportButton
                }

                self.supportersSection

                self.verifySection

                self.forkNote
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 460, height: 660)
        .background(.ultraThickMaterial)
        .overlay(alignment: .topTrailing) { self.closeButton }
        .task {
            // Re-check the remembered email so a lapsed subscription stops counting.
            await self.support.refreshFromKofi()
            self.supporters = await self.support.fetchSupporters()
        }
    }

    // MARK: - Verify

    @ViewBuilder
    private var verifySection: some View {
        if self.support.isVerificationConfigured {
            VStack(alignment: .leading, spacing: 8) {
                if self.support.isSupporter, let email = self.support.verifiedEmail {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Verified as \(email)", comment: "Verified supporter email")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Forget") { self.support.forgetVerification() }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Already supported? Verify it", comment: "Verify heading")
                        .font(.subheadline.weight(.semibold))
                    Text("Enter the email you used on Ko-fi. It can take a minute after paying.", comment: "Verify hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        TextField("you@email.com", text: self.$email)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { self.runVerify() }

                        Button {
                            self.runVerify()
                        } label: {
                            if self.verifying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Verify", comment: "Verify button")
                            }
                        }
                        .disabled(self.verifying || self.email.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let message = self.verifyMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func runVerify() {
        let email = self.email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !self.verifying else { return }
        self.verifying = true
        self.verifyMessage = nil
        Task {
            let result = await self.support.verify(email: email)
            self.verifying = false
            switch result {
            case .supporter:
                self.verifyMessage = String(localized: "Verified — thank you! 💗")
            case .notFound:
                self.verifyMessage = String(localized: "No active support found for that email yet.")
            case .notConfigured:
                self.verifyMessage = String(localized: "Verification isn’t available yet.")
            case .failed:
                self.verifyMessage = String(localized: "Couldn’t reach the server — try again.")
            }
        }
    }

    private var closeButton: some View {
        Button { self.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(14)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(
                    LinearGradient(
                        colors: [Self.accent, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .shadow(color: Self.accent.opacity(0.4), radius: 12, y: 4)

            Text("Support KasetPlus", comment: "Support sheet title")
                .font(.title2.weight(.bold))

            Text("KasetPlus is built and maintained by one person, in the open. If it makes your day a little better, you can help keep it going. 💗", comment: "Support sheet subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - Supporter card (active status)

    @ViewBuilder
    private var supporterCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                Text("You’re a Supporter", comment: "Active supporter heading")
                    .fontWeight(.bold)
            }
            .font(.headline)
            .foregroundStyle(.white)

            Text(self.supporterDetail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Self.accent, .purple], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .shadow(color: Self.accent.opacity(0.3), radius: 10, y: 4)
    }

    private var supporterDetail: String {
        if let expiry = self.support.oneTimeExpiry {
            return String(localized: "Thanks for the tip — supporter perks are active until \(expiry.formatted(date: .abbreviated, time: .omitted)).")
        }
        return String(localized: "Thanks for your monthly support — you’re keeping the lights on. 🙏")
    }

    // MARK: - Support options

    private var supportButton: some View {
        self.optionButton(
            title: String(localized: "Support on Ko-fi"),
            subtitle: String(localized: "One-time tip or monthly membership — your choice"),
            systemImage: "heart.fill",
            prominent: true
        ) {
            self.openURL(SupportManager.forkKofiURL)
        }
    }

    private func optionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(prominent ? .white : Self.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(prominent ? .white : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(prominent ? .white.opacity(0.85) : .secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(prominent ? .white.opacity(0.9) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(self.optionBackground(prominent: prominent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionBackground(prominent: Bool) -> some View {
        if prominent {
            LinearGradient(colors: [Self.accent, .purple], startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Self.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Self.accent.opacity(0.28), lineWidth: 1)
                }
        }
    }

    // MARK: - Fork note

    private var forkNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("A note about the project", comment: "Fork note heading")
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("KasetPlus is an independent fork of the open-source **Kaset** by sozercan. Supporting here helps this fork. If you’d like, you can also support the original project — that won’t change your supporter status here.", comment: "Fork support note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                self.openURL(SupportManager.baseKofiURL)
            } label: {
                HStack(spacing: 5) {
                    Text("Support the original Kaset", comment: "Upstream support link")
                    Image(systemName: "arrow.up.forward")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Supporters wall

    @ViewBuilder
    private var supportersSection: some View {
        if !self.supporters.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Supporters", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(self.supporters.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 74), spacing: 8)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(self.visibleSupporters) { supporter in
                        self.supporterCell(supporter)
                    }
                }

                if self.supporters.count > Self.supporterPreviewCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { self.showAllSupporters.toggle() }
                    } label: {
                        Text(self.showAllSupporters
                            ? String(localized: "Show fewer")
                            : String(localized: "Show all \(self.supporters.count)"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Self.accent)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var visibleSupporters: [SupportManager.Supporter] {
        self.showAllSupporters
            ? self.supporters
            : Array(self.supporters.prefix(Self.supporterPreviewCount))
    }

    private func supporterCell(_ supporter: SupportManager.Supporter) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Self.accent, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text(Self.initials(supporter.name))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 50, height: 50)

            Text(supporter.name)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Subscribers show a heart + number of months supported.
            if supporter.isSubscriber, supporter.months > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Self.accent)
                    Text("\(supporter.months)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Self.accent.opacity(0.14)))
            } else {
                Color.clear.frame(height: 16)
            }
        }
        .frame(width: 74)
    }

    private static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }
}

#Preview {
    SupportView()
}
