import SwiftUI

struct PRDetailView: View {
    let pr: PullRequest
    @EnvironmentObject var appState: AppState

    @State private var diffFiles: [DiffFile] = []
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var workflowRuns: [WorkflowRun] = []
    @State private var isLoadingRuns = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Workflow runs
                if isLoadingRuns || !workflowRuns.isEmpty {
                    workflowRunsView
                    Divider()
                }

                // Diff content
                if isLoadingDiff {
                    ProgressView("Loading diff...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = diffError {
                    VStack {
                        Text("Failed to load diff")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(diffFiles) { file in
                            DiffFileView(file: file)
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear { loadDiff() }
        .onChange(of: pr) { loadDiff() }
    }


    private var failedRuns: [WorkflowRun] {
        workflowRuns.filter { $0.conclusion == "failure" }
    }

    private var inProgressRuns: [WorkflowRun] {
        workflowRuns.filter { $0.status == "in_progress" }
    }

    @ViewBuilder
    private var workflowRunsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoadingRuns {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking workflows...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // In-progress runs
                ForEach(inProgressRuns) { run in
                    if let url = URL(string: run.htmlURL) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(run.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Failed runs with details
                ForEach(failedRuns) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        if let url = URL(string: run.htmlURL) {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    Text(run.name)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        if let message = run.failureMessage {
                            Text(message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.8))
                                .textSelection(.enabled)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }

                // Passed/skipped/other runs
                let otherRuns = workflowRuns.filter { $0.conclusion != "failure" && $0.status != "in_progress" }
                ForEach(otherRuns) { run in
                    if let url = URL(string: run.htmlURL) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                runStatusIcon(run)
                                    .font(.caption)
                                Text(run.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func runStatusIcon(_ run: WorkflowRun) -> some View {
        switch run.conclusion {
        case "success":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "skipped":
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
        case "cancelled":
            Image(systemName: "slash.circle.fill").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func loadDiff() {
        diffFiles = []
        diffError = nil
        isLoadingDiff = true
        isLoadingRuns = true

        let pat = appState.pat
        guard !pat.isEmpty else {
            diffError = "No GitHub PAT configured"
            isLoadingDiff = false
            isLoadingRuns = false
            return
        }

        let api = GitHubAPI(pat: pat)
        Task {
            do {
                let files = try await api.fetchDiffFiles(repo: pr.repo, number: pr.number)
                diffFiles = files
            } catch {
                diffError = error.localizedDescription
            }
            isLoadingDiff = false
        }
        Task {
            do {
                var runs = try await api.fetchWorkflowRuns(repo: pr.repo, number: pr.number)
                // Fetch failure details for failed runs
                for i in runs.indices where runs[i].conclusion == "failure" {
                    if let message = try? await api.fetchRunFailureMessage(repo: pr.repo, runId: runs[i].id) {
                        runs[i].failureMessage = message
                    }
                }
                workflowRuns = runs
            } catch {
                print("Failed to load workflow runs: \(error)")
            }
            isLoadingRuns = false
        }
        if !appState.isApproved(pr) {
            Task {
                do {
                    let currentUser = try await api.fetchCurrentUser()
                    let approvals = try await api.fetchApprovals(repo: pr.repo, number: pr.number)
                    if approvals.contains(where: { $0.author == currentUser }) {
                        appState.markApproved(pr)
                    }
                } catch {}
            }
        }
    }
}

struct DiffFileView: View {
    let file: DiffFile

    private var lineCount: Int {
        file.patch?.components(separatedBy: "\n").count ?? 0
    }

    private static let previewLineCount = 40
    @State private var isExpanded = false

    private var lines: [String] {
        file.patch?.components(separatedBy: "\n") ?? []
    }

    private var isLargeFile: Bool {
        lines.count > Self.previewLineCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack {
                statusIcon
                Text(file.filename)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor))

            // Diff content
            if let _ = file.patch {
                let visibleLines = isExpanded || !isLargeFile ? lines : Array(lines.prefix(Self.previewLineCount))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }

                if isLargeFile && !isExpanded {
                    Button {
                        isExpanded = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Show \(lines.count - Self.previewLineCount) more lines")
                                .font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                        .background(Color(.controlBackgroundColor).opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Binary file or no diff available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separatorColor), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch file.status {
        case "added":
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
        case "removed":
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
        case "renamed":
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.blue)
        default:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct DiffLineView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .background(backgroundColor)
    }

    private var backgroundColor: Color {
        if line.hasPrefix("@@") {
            return Color(.systemBlue).opacity(0.1)
        } else if line.hasPrefix("+") {
            return Color(.systemGreen).opacity(0.15)
        } else if line.hasPrefix("-") {
            return Color(.systemRed).opacity(0.15)
        }
        return .clear
    }
}
