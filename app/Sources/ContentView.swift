import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            PRListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } content: {
            if let pr = appState.selectedPR {
                PRInfoView(pr: pr)
            } else {
                Text("Select a pull request")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            if let pr = appState.selectedPR {
                PRDetailView(pr: pr)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a pull request")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            // PR number as clickable title in center
            ToolbarItem(placement: .principal) {
                if let pr = appState.selectedPR, let url = URL(string: pr.htmlURL) {
                    PRTitleLink(pr: pr, url: url)
                }
            }

            // Approve button on the right
            ToolbarItem(placement: .automatic) {
                if let pr = appState.selectedPR, pr.author != appState.currentUsername {
                    PRToolbarApproveButton(pr: pr)
                }
            }
        }
        .onAppear {
            Task {
                await appState.refreshPRs()
            }
            appState.connectWebSocket()
        }
    }
}

struct PRTitleLink: View {
    let pr: PullRequest
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Text("\(pr.repo)#\(pr.number)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .underline(isHovered)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct PRToolbarApproveButton: View {
    let pr: PullRequest
    @EnvironmentObject var appState: AppState
    @State private var isApproving = false
    @State private var isHovered = false

    var body: some View {
        if appState.isApproved(pr) || appState.hasHumanApproval(pr) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.caption)
                Text("Approved")
                    .font(.caption)
            }
            .foregroundStyle(.green)
        } else if isApproving {
            ProgressView()
                .controlSize(.small)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.caption)
                Text("Approve")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isHovered ? .white : Color.green.opacity(0.8))
            .background(
                Capsule().fill(isHovered ? Color.green.opacity(0.7) : Color.clear)
            )
            .overlay(
                Capsule().stroke(Color.green.opacity(isHovered ? 0.7 : 0.3), lineWidth: 1)
            )
            .contentShape(Capsule())
            .onTapGesture {
                Task { await approve() }
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
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
}
