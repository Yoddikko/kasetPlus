import SwiftUI

// MARK: - YouTubeReportSheet

/// Native "Report video" sheet: fetches YouTube's own report form
/// (`flag/get_form`), lets the user pick a reason, and submits it
/// (`flag/flag`) — the same flow as the web "Report" dialog.
///
/// ponytail: reason parsing is best-effort (the live `get_form` shape couldn't
/// be captured signed-in), so an empty form degrades to a clear message rather
/// than a broken list.
struct YouTubeReportSheet: View {
    let reportParams: String
    let client: any YouTubeClientProtocol

    @Environment(\.dismiss) private var dismiss

    @State private var form: YouTubeReportForm?
    @State private var loading = true
    @State private var selectedReasonId: String?
    @State private var submitting = false
    @State private var submitted = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.form?.title ?? String(localized: "Report video", comment: "Report sheet title"))
                    .font(.headline)
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let reasons = self.form?.reasons, !reasons.isEmpty, !self.submitted {
                Divider()
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel", comment: "Cancel report")) { self.dismiss() }
                    Button {
                        Task { await self.submit() }
                    } label: {
                        if self.submitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Report", comment: "Submit report button")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.selectedReasonId == nil || self.submitting)
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 460)
        .task { await self.load() }
    }

    @ViewBuilder private var content: some View {
        if self.loading {
            self.centered { ProgressView() }
        } else if self.submitted {
            self.centered {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    Text("Thanks — your report was sent.", comment: "Report submitted confirmation")
                        .font(.callout)
                }
            }
        } else if let errorText {
            self.centered {
                Text(errorText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else if let reasons = self.form?.reasons, !reasons.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(reasons) { reason in
                        self.reasonRow(reason)
                    }
                }
                .padding(.vertical, 6)
            }
        } else {
            self.centered {
                Text("Reporting isn't available for this video.", comment: "Report form empty/unavailable")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func reasonRow(_ reason: YouTubeReportForm.Reason) -> some View {
        Button {
            self.selectedReasonId = reason.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: self.selectedReasonId == reason.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(self.selectedReasonId == reason.id ? SettingsManager.shared.accentColor : .secondary)
                Text(reason.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func centered(@ViewBuilder _ inner: () -> some View) -> some View {
        HStack { Spacer(); inner(); Spacer() }.frame(maxHeight: .infinity)
    }

    private func load() async {
        do {
            self.form = try await self.client.getReportForm(params: self.reportParams)
        } catch {
            self.errorText = String(localized: "Couldn't load the report form.", comment: "Report form load error")
        }
        self.loading = false
    }

    private func submit() async {
        guard let reason = self.form?.reasons.first(where: { $0.id == self.selectedReasonId }) else { return }
        self.submitting = true
        defer { self.submitting = false }
        do {
            try await self.client.submitReport(params: reason.submitParams)
            self.submitted = true
        } catch {
            self.errorText = String(localized: "Couldn't send the report.", comment: "Report submit error")
        }
    }
}
