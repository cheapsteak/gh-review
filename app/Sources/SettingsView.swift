import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var pat: String = ""
    @State private var relayURL: String = ""
    @State private var relayToken: String = ""
    @State private var repos: String = ""
    @State private var hiddenAuthors: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("GitHub") {
                SecureField("Personal Access Token", text: $pat)
                    .textFieldStyle(.roundedBorder)
                Text("Required scopes: repo, read:org")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Relay Server") {
                TextField("WebSocket URL", text: $relayURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Relay Token", text: $relayToken)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Repositories") {
                TextField("Comma-separated repos (e.g. owner/repo1, owner/repo2)", text: $repos)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Hidden Authors") {
                TextField("Comma-separated usernames to hide", text: $hiddenAuthors)
                    .textFieldStyle(.roundedBorder)
                Text("PRs from these authors won't appear. e.g. dependabot[bot], mr-claudeseeks[bot]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save") {
                        appState.pat = pat
                        appState.relayURL = relayURL
                        appState.relayToken = relayToken
                        appState.repos = repos
                        appState.hiddenAuthors = hiddenAuthors
                        appState.setupAPI()
                        appState.connectWebSocket()
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            saved = false
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 400)
        .onAppear {
            pat = appState.pat
            relayURL = appState.relayURL
            relayToken = appState.relayToken
            repos = appState.repos
            hiddenAuthors = appState.hiddenAuthors
        }
    }
}
