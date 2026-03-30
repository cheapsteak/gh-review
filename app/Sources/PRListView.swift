import SwiftUI

struct PRListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isLoading && appState.pullRequests.isEmpty {
                ProgressView("Loading pull requests...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.pullRequests.isEmpty {
                VStack(spacing: 8) {
                    Text("No pull requests")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Configure repos in Settings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.filteredPullRequests, selection: $appState.selectedPR) { pr in
                    PRRowView(pr: pr)
                        .tag(pr)
                }
                .listStyle(.sidebar)
                .onChange(of: appState.selectedPR) { _, newPR in
                    guard let pr = newPR, pr.isNew,
                          let idx = appState.pullRequests.firstIndex(where: { $0.id == pr.id }) else { return }
                    appState.pullRequests[idx].isNew = false
                    appState.selectedPR = appState.pullRequests[idx]
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = appState.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Menu {
                        Toggle("Needs review", isOn: $appState.needsReviewOnly)
                        Toggle("Hide drafts", isOn: $appState.hideDrafts)
                        Toggle("Hide closed", isOn: $appState.hideClosed)
                    } label: {
                        Image(systemName: appState.hasActiveFilters
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter pull requests")

                    Button {
                        Task { await appState.refreshPRs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(appState.isLoading)
                    .help("Refresh pull requests")

                    Button {
                        appState.myPRsOnly.toggle()
                    } label: {
                        Image(systemName: appState.myPRsOnly
                              ? "person.fill"
                              : "person")
                    }
                    .help("Show only my PRs")

                    Circle()
                        .fill(appState.webSocketService.isConnected ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                        .help(appState.webSocketService.isConnected ? "Live updates connected" : "Live updates disconnected")
                }
            }
        }
    }
}

struct PRRowView: View {
    let pr: PullRequest
    @EnvironmentObject var appState: AppState

    var approvals: [PRApproval] { appState.approvals(for: pr) }
    @State private var isApproving = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if pr.isNew {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    AsyncImage(url: URL(string: pr.avatarURL)) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())

                    Text(pr.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(PullRequest.relativeTime(from: pr.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 4) {
                    // Approve status / button
                    if appState.hasHumanApproval(pr) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("Approved by a human reviewer")
                    } else if pr.author != appState.currentUsername {
                        if isApproving {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            ApproveButton {
                                Task { await approve() }
                            }
                        }
                    }

                    // Approval pills
                    ForEach(approvals, id: \.author) { approval in
                        HStack(spacing: 3) {
                            AsyncImage(url: URL(string: approval.avatarURL)) { image in
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 14, height: 14)
                            .clipShape(Circle())

                            Text(approval.author)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { loadApprovals() }
    }

    private func approve() async {
        guard !appState.pat.isEmpty else { return }
        isApproving = true
        let api = GitHubAPI(pat: appState.pat)
        do {
            try await api.approvePR(repo: pr.repo, number: pr.number)
            let user = try await api.fetchCurrentUser()
            appState.markApproved(pr)
            var current = appState.approvals(for: pr)
            if !current.contains(where: { $0.author == user }) {
                current.append(PRApproval(author: user, avatarURL: ""))
                appState.setApprovals(current, for: pr)
            }
        } catch {}
        isApproving = false
    }

    private func loadApprovals() {
        guard !appState.pat.isEmpty else { return }
        // Skip if already loaded
        if !appState.approvals(for: pr).isEmpty { return }
        let api = GitHubAPI(pat: appState.pat)
        Task {
            do {
                async let fetchedApprovals = api.fetchApprovals(repo: pr.repo, number: pr.number)
                async let currentUser = api.fetchCurrentUser()
                let approvals = try await fetchedApprovals
                let user = try await currentUser
                appState.currentUsername = user
                appState.setApprovals(approvals, for: pr)
                if approvals.contains(where: { $0.author == user }) {
                    appState.markApproved(pr)
                }
            } catch {}
        }
    }
}

struct ApproveButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.caption2)
                Text("Approve")
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isHovered ? .white : Color.green.opacity(0.8))
            .background(
                Capsule().fill(isHovered ? Color.green.opacity(0.7) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(Color.green.opacity(isHovered ? 0.7 : 0.3), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}
