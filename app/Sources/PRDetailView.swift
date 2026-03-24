import SwiftUI
import Highlightr

struct PRDetailView: View {
    let pr: PullRequest
    @EnvironmentObject var appState: AppState

    @State private var diffFiles: [DiffFile] = []
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var workflowRuns: [WorkflowRun] = []
    @State private var isLoadingRuns = false
    @State private var generatedPatterns: [String] = []
    @State private var collapsedFiles: Set<String> = []

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
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(diffFiles) { file in
                            let isCollapsed = collapsedFiles.contains(file.filename)
                            Section {
                                if !isCollapsed {
                                    DiffFileContentView(file: file)
                                }
                            } header: {
                                DiffFileHeaderView(file: file, isCollapsed: isCollapsed) {
                                    if collapsedFiles.contains(file.filename) {
                                        collapsedFiles.remove(file.filename)
                                    } else {
                                        collapsedFiles.insert(file.filename)
                                    }
                                }
                            }
                        }
                    }
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

    private func shouldCollapseByDefault(_ file: DiffFile) -> Bool {
        if file.patch == nil { return true }
        for pattern in generatedPatterns {
            if matchGlob(pattern: pattern, path: file.filename) { return true }
        }
        return false
    }

    private func applyDefaultCollapseState() {
        for file in diffFiles where shouldCollapseByDefault(file) {
            collapsedFiles.insert(file.filename)
        }
    }

    private func loadDiff() {
        diffFiles = []
        diffError = nil
        isLoadingDiff = true
        isLoadingRuns = true
        generatedPatterns = []
        collapsedFiles = []

        let pat = appState.pat
        guard !pat.isEmpty else {
            diffError = "No GitHub PAT configured"
            isLoadingDiff = false
            isLoadingRuns = false
            return
        }

        let api = GitHubAPI(pat: pat)
        Task {
            async let filesTask = api.fetchDiffFiles(repo: pr.repo, number: pr.number)
            async let patternsTask: [String] = (try? api.fetchGeneratedPatterns(repo: pr.repo)) ?? []
            do {
                let files = try await filesTask
                let patterns = await patternsTask
                diffFiles = files
                generatedPatterns = patterns
                applyDefaultCollapseState()
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

// Shared highlighter instance
private let sharedHighlightr: Highlightr? = {
    let h = Highlightr()
    h?.setTheme(to: "github")
    return h
}()

private func languageForFilename(_ filename: String) -> String? {
    let ext = (filename as NSString).pathExtension.lowercased()
    let map: [String: String] = [
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript",
        "jsx": "javascript", "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "cpp": "cpp", "c": "c", "h": "c", "hpp": "cpp",
        "cs": "csharp", "css": "css", "scss": "scss", "html": "xml", "xml": "xml",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini", "sql": "sql",
        "sh": "bash", "bash": "bash", "zsh": "bash", "md": "markdown", "tf": "hcl",
        "graphql": "graphql", "gql": "graphql", "proto": "protobuf",
    ]
    return map[ext]
}

struct DiffFileHeaderView: View {
    let file: DiffFile
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            statusIcon
            Text(file.filename)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
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
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .overlay(alignment: .bottom) {
            Divider()
        }
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

struct DiffFileContentView: View {
    let file: DiffFile
    @State private var isFullyExpanded = false

    private static let previewLineCount = 40

    private var lines: [String] {
        file.patch?.components(separatedBy: "\n") ?? []
    }

    private var isLargeFile: Bool {
        lines.count > Self.previewLineCount
    }

    private var highlightedLines: [HighlightedDiffLine] {
        let lang = languageForFilename(file.filename)
        return buildHighlightedLines(lines: lines, language: lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if file.patch != nil {
                let allLines = highlightedLines
                let visibleLines = isFullyExpanded || !isLargeFile ? allLines : Array(allLines.prefix(Self.previewLineCount))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        DiffHighlightedLineView(line: line)
                    }
                }

                if isLargeFile && !isFullyExpanded {
                    Button {
                        isFullyExpanded = true
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
    }
}

private func matchGlob(pattern: String, path: String) -> Bool {
    // Simple glob matching supporting * and **
    let regexPattern = "^" + pattern
        .replacingOccurrences(of: ".", with: "\\.")
        .replacingOccurrences(of: "**", with: "<<<GLOBSTAR>>>")
        .replacingOccurrences(of: "*", with: "[^/]*")
        .replacingOccurrences(of: "<<<GLOBSTAR>>>", with: ".*")
    + "$"
    return path.range(of: regexPattern, options: .regularExpression) != nil
}

struct HighlightedDiffLine {
    let attributed: NSAttributedString
    let background: Color
}

private func buildHighlightedLines(lines: [String], language: String?) -> [HighlightedDiffLine] {
    guard let highlightr = sharedHighlightr else {
        // Fallback: no highlighting
        return lines.map { line in
            let bg = diffBackground(for: line)
            let attr = NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
            return HighlightedDiffLine(attributed: attr, background: bg)
        }
    }

    // Extract code content (strip +/- prefix), highlight as one block, then split back
    var codeLines: [String] = []
    var prefixes: [String] = []
    for line in lines {
        if line.hasPrefix("@@") || line.isEmpty {
            codeLines.append(line)
            prefixes.append("")
        } else if line.hasPrefix("+") || line.hasPrefix("-") {
            prefixes.append(String(line.prefix(1)))
            codeLines.append(String(line.dropFirst()))
        } else if line.hasPrefix(" ") {
            prefixes.append(" ")
            codeLines.append(String(line.dropFirst()))
        } else {
            prefixes.append("")
            codeLines.append(line)
        }
    }

    let fullCode = codeLines.joined(separator: "\n")
    let highlighted = highlightr.highlight(fullCode, as: language)

    guard let highlighted else {
        return lines.map { line in
            HighlightedDiffLine(
                attributed: NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                ]),
                background: diffBackground(for: line)
            )
        }
    }

    // Split the highlighted attributed string back into lines
    let fullString = highlighted.string
    var lineRanges: [NSRange] = []
    var searchStart = fullString.startIndex
    for (i, codeLine) in codeLines.enumerated() {
        let lineStart = fullString.distance(from: fullString.startIndex, to: searchStart)
        let lineLength = codeLine.count
        lineRanges.append(NSRange(location: lineStart, length: lineLength))
        // Move past this line + newline
        let advance = lineLength + (i < codeLines.count - 1 ? 1 : 0)
        searchStart = fullString.index(searchStart, offsetBy: min(advance, fullString.distance(from: searchStart, to: fullString.endIndex)))
    }

    var result: [HighlightedDiffLine] = []
    let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    for (i, line) in lines.enumerated() {
        let bg = diffBackground(for: line)

        if i < lineRanges.count {
            let range = lineRanges[i]
            let clampedRange = NSRange(
                location: range.location,
                length: min(range.length, highlighted.length - range.location)
            )
            if clampedRange.length > 0 {
                let lineAttr = NSMutableAttributedString()
                // Add prefix back
                let prefix = prefixes[i]
                if !prefix.isEmpty {
                    lineAttr.append(NSAttributedString(string: prefix, attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor.labelColor
                    ]))
                }
                let codePart = NSMutableAttributedString(attributedString: highlighted.attributedSubstring(from: clampedRange))
                let codeRange = NSRange(location: 0, length: codePart.length)
                // Override font to ensure consistent monospace
                codePart.addAttribute(.font, value: monoFont, range: codeRange)
                // Enforce minimum contrast — replace too-light foreground colors
                codePart.enumerateAttribute(.foregroundColor, in: codeRange) { value, attrRange, _ in
                    if let color = value as? NSColor, colorIsTooPale(color) {
                        codePart.addAttribute(.foregroundColor, value: NSColor.labelColor, range: attrRange)
                    }
                }
                lineAttr.append(codePart)
                result.append(HighlightedDiffLine(attributed: lineAttr, background: bg))
            } else {
                result.append(HighlightedDiffLine(
                    attributed: NSAttributedString(string: line, attributes: [.font: monoFont]),
                    background: bg
                ))
            }
        } else {
            result.append(HighlightedDiffLine(
                attributed: NSAttributedString(string: line, attributes: [.font: monoFont]),
                background: bg
            ))
        }
    }

    return result
}

private func colorIsTooPale(_ color: NSColor) -> Bool {
    guard let rgb = color.usingColorSpace(.sRGB) else { return false }
    // Relative luminance (WCAG formula)
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance > 0.6
}

private func diffBackground(for line: String) -> Color {
    if line.hasPrefix("@@") {
        return Color(.systemBlue).opacity(0.1)
    } else if line.hasPrefix("+") {
        return Color(.systemGreen).opacity(0.15)
    } else if line.hasPrefix("-") {
        return Color(.systemRed).opacity(0.15)
    }
    return .clear
}

struct DiffHighlightedLineView: View {
    let line: HighlightedDiffLine

    var body: some View {
        Text(AttributedString(line.attributed))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .background(line.background)
    }
}
