import Foundation

actor GitHubAPI {
    private let baseURL = "https://api.github.com"
    private let session: URLSession
    private let pat: String

    init(pat: String) {
        self.pat = pat
        self.session = URLSession.shared
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private var cachedUsername: String?

    func fetchCurrentUser() async throws -> String {
        if let cached = cachedUsername { return cached }
        guard let url = URL(string: "\(baseURL)/user") else { throw URLError(.badURL) }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        struct UserResponse: Codable { let login: String }
        let user = try JSONDecoder().decode(UserResponse.self, from: data)
        cachedUsername = user.login
        return user.login
    }

    func fetchOpenPRs(repo: String) async throws -> [PullRequest] {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls?state=open&sort=updated&direction=desc&per_page=50") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        let decoder = JSONDecoder()
        let responses = try decoder.decode([PullRequest.GitHubResponse].self, from: data)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        return responses.compactMap { response in
            let createdDate = formatter.date(from: response.created_at)
                ?? fallbackFormatter.date(from: response.created_at)
                ?? Date()
            let updatedDate = formatter.date(from: response.updated_at)
                ?? fallbackFormatter.date(from: response.updated_at)
                ?? Date()

            return PullRequest(
                number: response.number,
                title: response.title,
                repo: response.base.repo.full_name,
                author: response.user.login,
                avatarURL: response.user.avatar_url,
                body: response.body ?? "",
                htmlURL: response.html_url,
                createdAt: createdDate,
                updatedAt: updatedDate,
                isDraft: response.draft ?? false,
                state: response.state ?? "open"
            )
        }
    }

    func fetchDiffFiles(repo: String, number: Int) async throws -> [DiffFile] {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)/files") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct FileResponse: Codable {
            let filename: String
            let status: String
            let additions: Int
            let deletions: Int
            let patch: String?
        }

        let files = try JSONDecoder().decode([FileResponse].self, from: data)
        return files.map { file in
            DiffFile(
                filename: file.filename,
                status: file.status,
                additions: file.additions,
                deletions: file.deletions,
                patch: file.patch
            )
        }
    }

    func fetchApprovals(repo: String, number: Int) async throws -> [PRApproval] {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)/reviews") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct ReviewResponse: Codable {
            let state: String
            let user: UserResponse
            struct UserResponse: Codable {
                let login: String
                let avatar_url: String
            }
        }

        let responses = try JSONDecoder().decode([ReviewResponse].self, from: data)
        // Get unique approvers (last review state per user wins)
        var latestState: [String: ReviewResponse] = [:]
        for review in responses {
            latestState[review.user.login] = review
        }
        return latestState.values
            .filter { $0.state == "APPROVED" }
            .map { PRApproval(author: $0.user.login, avatarURL: $0.user.avatar_url) }
    }

    func fetchPRReviews(repo: String, number: Int) async throws -> [PRReview] {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)/reviews") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct ReviewResponse: Codable {
            let id: Int
            let body: String?
            let state: String
            let html_url: String
            let submitted_at: String?
            let user: UserResponse

            struct UserResponse: Codable {
                let login: String
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let responses = try JSONDecoder().decode([ReviewResponse].self, from: data)
        return responses
            .filter { $0.user.login.contains("longeye-claude-reviewer") }
            .compactMap { review in
                let date: Date
                if let dateStr = review.submitted_at {
                    date = formatter.date(from: dateStr)
                        ?? fallbackFormatter.date(from: dateStr)
                        ?? Date()
                } else {
                    date = Date()
                }
                return PRReview(
                    id: review.id,
                    author: review.user.login,
                    body: review.body ?? "",
                    state: review.state,
                    submittedAt: date,
                    htmlURL: review.html_url
                )
            }
            .sorted { $0.submittedAt > $1.submittedAt }
    }

    func fetchWorkflowRuns(repo: String, number: Int) async throws -> [WorkflowRun] {
        // First get the PR's head SHA
        guard let prURL = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)") else {
            throw URLError(.badURL)
        }
        let prRequest = authorizedRequest(url: prURL)
        let (prData, _) = try await session.data(for: prRequest)

        struct PRDetail: Codable {
            let head: Head
            struct Head: Codable { let sha: String }
        }

        let prDetail = try JSONDecoder().decode(PRDetail.self, from: prData)
        let sha = prDetail.head.sha

        // Then get workflow runs for that commit
        guard let runsURL = URL(string: "\(baseURL)/repos/\(repo)/actions/runs?head_sha=\(sha)") else {
            throw URLError(.badURL)
        }
        let runsRequest = authorizedRequest(url: runsURL)
        let (runsData, _) = try await session.data(for: runsRequest)

        struct WorkflowRunsResponse: Codable {
            let workflow_runs: [RunResponse]

            struct RunResponse: Codable {
                let id: Int
                let name: String
                let status: String
                let conclusion: String?
                let html_url: String
                let created_at: String
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let response = try JSONDecoder().decode(WorkflowRunsResponse.self, from: runsData)
        return response.workflow_runs
            .compactMap { run in
                let date = formatter.date(from: run.created_at)
                    ?? fallbackFormatter.date(from: run.created_at)
                    ?? Date()
                return WorkflowRun(
                    id: run.id,
                    name: run.name,
                    status: run.status,
                    conclusion: run.conclusion,
                    htmlURL: run.html_url,
                    createdAt: date
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func fetchRunFailureMessage(repo: String, runId: Int) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/actions/runs/\(runId)/jobs") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct JobsResponse: Codable {
            let jobs: [Job]
            struct Job: Codable {
                let name: String
                let conclusion: String?
                let steps: [Step]?
                struct Step: Codable {
                    let name: String
                    let conclusion: String?
                }
            }
        }

        let response = try JSONDecoder().decode(JobsResponse.self, from: data)

        // No jobs means workflow file error
        if response.jobs.isEmpty {
            return "Workflow file error"
        }

        // Find failed jobs and their failed steps
        var failures: [String] = []
        for job in response.jobs where job.conclusion == "failure" {
            if let steps = job.steps {
                let failedSteps = steps.filter { $0.conclusion == "failure" }.map(\.name)
                if !failedSteps.isEmpty {
                    failures.append("\(job.name): \(failedSteps.joined(separator: ", "))")
                } else {
                    failures.append(job.name)
                }
            } else {
                failures.append(job.name)
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func fetchPRComments(repo: String, number: Int) async throws -> [PRComment] {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/issues/\(number)/comments?per_page=100") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct CommentResponse: Codable {
            let id: Int
            let body: String?
            let html_url: String
            let created_at: String
            let user: UserResponse

            struct UserResponse: Codable {
                let login: String
                let avatar_url: String
                let type: String?  // "User" or "Bot"
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]

        let responses = try JSONDecoder().decode([CommentResponse].self, from: data)
        return responses.compactMap { comment in
            let date = formatter.date(from: comment.created_at)
                ?? fallback.date(from: comment.created_at)
                ?? Date()
            return PRComment(
                id: comment.id,
                author: comment.user.login,
                avatarURL: comment.user.avatar_url,
                body: comment.body ?? "",
                createdAt: date,
                htmlURL: comment.html_url,
                isBot: comment.user.type == "Bot"
            )
        }
    }

    struct MergeStatus {
        let mergeable: Bool?        // nil = still computing
        let mergeableState: String  // clean, dirty, unstable, blocked, unknown
    }

    struct ChecksStatus {
        let total: Int
        let completed: Int
        let passed: Int  // success + skipped + neutral
        var allPassed: Bool { total > 0 && completed == total && passed == total }
        var anyFailed: Bool { completed > passed }
        var pending: Bool { completed < total }
    }

    func fetchChecksStatus(repo: String, number: Int) async throws -> ChecksStatus {
        // Get head SHA
        guard let prURL = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)") else {
            throw URLError(.badURL)
        }
        let prRequest = authorizedRequest(url: prURL)
        let (prData, _) = try await session.data(for: prRequest)

        struct PRHead: Codable { let head: Head; struct Head: Codable { let sha: String } }
        let sha = try JSONDecoder().decode(PRHead.self, from: prData).head.sha

        // Get check runs
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/commits/\(sha)/check-runs?per_page=100") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct CheckRunsResponse: Codable {
            let total_count: Int
            let check_runs: [CheckRun]
            struct CheckRun: Codable {
                let status: String
                let conclusion: String?
            }
        }

        let response = try JSONDecoder().decode(CheckRunsResponse.self, from: data)
        let completed = response.check_runs.filter { $0.status == "completed" }.count
        let passed = response.check_runs.filter {
            $0.conclusion == "success" || $0.conclusion == "skipped" || $0.conclusion == "neutral"
        }.count

        return ChecksStatus(total: response.total_count, completed: completed, passed: passed)
    }

    func fetchMergeStatus(repo: String, number: Int) async throws -> MergeStatus {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)

        struct PRDetailResponse: Codable {
            let mergeable: Bool?
            let mergeable_state: String?
        }

        let detail = try JSONDecoder().decode(PRDetailResponse.self, from: data)
        return MergeStatus(mergeable: detail.mergeable, mergeableState: detail.mergeable_state ?? "unknown")
    }

    private func fetchPRNodeId(repo: String, number: Int) async throws -> String {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)") else {
            throw URLError(.badURL)
        }
        let request = authorizedRequest(url: url)
        let (data, _) = try await session.data(for: request)
        struct PRNodeResponse: Codable { let node_id: String }
        return try JSONDecoder().decode(PRNodeResponse.self, from: data).node_id
    }

    func enqueuePR(repo: String, number: Int) async throws {
        let nodeId = try await fetchPRNodeId(repo: repo, number: number)

        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw URLError(.badURL)
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mutation = """
        mutation { enqueuePullRequest(input: { pullRequestId: "\(nodeId)" }) { mergeQueueEntry { id position state } } }
        """
        request.httpBody = try JSONEncoder().encode(["query": mutation])

        let (data, _) = try await session.data(for: request)

        struct GQLResponse: Codable {
            let errors: [GQLError]?
            struct GQLError: Codable { let message: String }
        }
        if let result = try? JSONDecoder().decode(GQLResponse.self, from: data),
           let errors = result.errors, !errors.isEmpty {
            throw URLError(.badServerResponse)
        }
    }

    func mergePR(repo: String, number: Int) async throws {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)/merge") else {
            throw URLError(.badURL)
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["merge_method": "squash"]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func fetchGeneratedPatterns(repo: String) async throws -> [String] {
        // Fetch .gitattributes from repo root
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/contents/.gitattributes") else {
            throw URLError(.badURL)
        }
        var request = authorizedRequest(url: url)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        guard let content = String(data: data, encoding: .utf8) else { return [] }

        // Parse lines like: "path/pattern linguist-generated" or "path/pattern linguist-generated=true"
        var patterns: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.contains("linguist-generated") || trimmed.contains("binary") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if let pattern = parts.first {
                    patterns.append(String(pattern))
                }
            }
        }
        return patterns
    }

    func approvePR(repo: String, number: Int) async throws {
        guard let url = URL(string: "\(baseURL)/repos/\(repo)/pulls/\(number)/reviews") else {
            throw URLError(.badURL)
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "event": "APPROVE"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
