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
            // Approve button on the left
            ToolbarItem(placement: .navigation) {
                if let pr = appState.selectedPR, pr.author != appState.currentUsername {
                    PRToolbarApproveButton(pr: pr)
                }
            }

            // PR number as clickable title in center
            ToolbarItem(placement: .principal) {
                if let pr = appState.selectedPR, let url = URL(string: pr.htmlURL) {
                    PRTitleLink(pr: pr, url: url)
                }
            }

            // Merge / Queue buttons
            ToolbarItem(placement: .automatic) {
                if let pr = appState.selectedPR {
                    PRToolbarMergeButtons(pr: pr)
                }
            }
        }
        .onAppear {
            Task {
                await appState.refreshPRs()
            }
            appState.connectWebSocket()
        }
        .onChange(of: appState.selectedPR) { _, newPR in
            guard let pr = newPR, pr.state == "open" else { return }
            Task { await appState.refreshMergeStatus(repo: pr.repo, number: pr.number) }
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

    var body: some View {
        if appState.isApproved(pr) {
            Label("Approved", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.green)
        } else if isApproving {
            ProgressView()
                .controlSize(.small)
        } else {
            Button {
                Task { await approve() }
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .tint(.green)
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

struct PRToolbarMergeButtons: View {
    let pr: PullRequest
    @EnvironmentObject var appState: AppState
    @State private var isWorking = false

    private var key: String { "\(pr.repo)#\(pr.number)" }
    private var status: GitHubAPI.MergeStatus? { appState.mergeStatus[key] }
    private var isQueued: Bool { appState.mergeQueued.contains(key) }

    // blocked + mergeable = merge queue repo; clean + mergeable = direct merge
    private var hasMergeQueue: Bool {
        status?.mergeableState == "blocked" && status?.mergeable == true
    }

    var body: some View {
        if pr.state == "merged" {
            statusLabel("Merged", icon: "arrow.triangle.merge", color: .green)
        } else if pr.state == "closed" {
            EmptyView()
        } else if isQueued {
            statusLabel("Queued", icon: "clock.arrow.circlepath", color: .orange)
        } else if isWorking {
            ProgressView()
                .controlSize(.small)
        } else if let status = status, status.mergeable == true {
            if hasMergeQueue {
                Button {
                    Task { await enqueue() }
                } label: {
                    Label("Queue to merge", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                Button {
                    Task { await merge() }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        } else if let status = status, status.mergeable == false {
            statusLabel(status.mergeableState == "dirty" ? "Conflicts" : "Not mergeable", icon: "xmark.circle", color: .secondary)
        } else {
            EmptyView()
        }
    }

    private func statusLabel(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func merge() async {
        isWorking = true
        await appState.mergePR(repo: pr.repo, number: pr.number)
        isWorking = false
    }

    private func enqueue() async {
        isWorking = true
        await appState.enqueuePR(repo: pr.repo, number: pr.number)
        isWorking = false
    }
}

