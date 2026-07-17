import SwiftUI

// MARK: - Issue compose

struct IssueComposeView: View {
    @Bindable var viewModel: CommunityViewModel
    @State private var auth = GitHubAuthService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var template: GitHubIssueTemplate = .blank
    @State private var title = ""
    @State private var bodyText = ""
    @State private var includeDiagnostics = true

    var body: some View {
        VStack(spacing: 0) {
            self.composeHeader(title: String(localized: "Report an issue"))
            Divider()

            if !self.auth.isSignedIn {
                GitHubSignInGate(message: String(localized: "Sign in with GitHub to file an issue."))
            } else {
                self.form
            }
        }
        .frame(width: 560, height: 600)
    }

    private var form: some View {
        Form {
            if !self.viewModel.templates.isEmpty {
                Picker(String(localized: "Template"), selection: self.$template) {
                    ForEach(self.viewModel.templates) { template in
                        Text(template.name).tag(template)
                    }
                }
                .onChange(of: self.template) { _, newValue in
                    self.title = newValue.titlePrefix
                    self.bodyText = newValue.body
                }
                if !self.template.about.isEmpty {
                    Text(self.template.about)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "Title")) {
                TextField(String(localized: "Short summary"), text: self.$title)
            }

            Section(String(localized: "Description")) {
                TextEditor(text: self.$bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
            }

            Section {
                Toggle(isOn: self.$includeDiagnostics) {
                    Text("Attach diagnostics (app & macOS version, hardware, recent logs)")
                }
                if self.includeDiagnostics {
                    Text("Review-able in the issue body before it's posted. No cookies, tokens, or account data are included.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func composeHeader(title: String) -> some View {
        HStack {
            Button(String(localized: "Cancel")) { self.dismiss() }
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Button(String(localized: "Submit")) {
                Task {
                    if await self.viewModel.submitIssue(
                        title: self.title,
                        body: self.bodyText,
                        labels: self.template.labels,
                        includeDiagnostics: self.includeDiagnostics
                    ) != nil {
                        self.dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.viewModel.isSubmitting)
        }
        .padding(12)
    }
}

// MARK: - Discussion compose

struct DiscussionComposeView: View {
    @Bindable var viewModel: CommunityViewModel
    @State private var auth = GitHubAuthService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var categoryID = ""
    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "Cancel")) { self.dismiss() }
                Spacer()
                Text("New discussion", comment: "Discussion compose title").font(.headline)
                Spacer()
                Button(String(localized: "Post")) {
                    Task {
                        if await self.viewModel.submitDiscussion(
                            title: self.title, body: self.bodyText, categoryID: self.categoryID
                        ) != nil {
                            self.dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || self.categoryID.isEmpty || self.viewModel.isSubmitting)
            }
            .padding(12)
            Divider()

            if !self.auth.isSignedIn {
                GitHubSignInGate(message: String(localized: "Sign in with GitHub to start a discussion."))
            } else {
                Form {
                    Picker(String(localized: "Category"), selection: self.$categoryID) {
                        Text(String(localized: "Choose…")).tag("")
                        ForEach(self.viewModel.categories) { category in
                            Text("\(category.emoji) \(category.name)").tag(category.id)
                        }
                    }
                    Section(String(localized: "Title")) {
                        TextField(String(localized: "Discussion title"), text: self.$title)
                    }
                    Section(String(localized: "Body")) {
                        TextEditor(text: self.$bodyText)
                            .font(.system(size: 12))
                            .frame(minHeight: 200)
                    }
                }
                .formStyle(.grouped)
                .task {
                    if self.viewModel.categories.isEmpty {
                        await self.viewModel.loadDiscussions()
                    }
                }
            }
        }
        .frame(width: 560, height: 560)
    }
}
