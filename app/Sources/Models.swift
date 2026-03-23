import Foundation

struct PullRequest: Identifiable, Codable, Hashable {
    var id: Int { number }
    let number: Int
    let title: String
    let repo: String        // "owner/repo"
    let author: String
    let avatarURL: String   // GitHub avatar URL for the author
    let body: String        // PR description/body text
    let htmlURL: String
    let createdAt: Date
    let updatedAt: Date
    let isDraft: Bool
    let state: String      // open, closed, merged
    var isNew: Bool = false // highlight recently arrived

    enum CodingKeys: String, CodingKey {
        case number, title, repo, author, body
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isDraft = "draft"
        case state
    }

    static func relativeTime(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        let months = days / 30
        return "\(months)mo ago"
    }

    // For decoding from GitHub API (different shape than relay)
    struct GitHubResponse: Codable {
        let number: Int
        let title: String
        let html_url: String
        let created_at: String
        let updated_at: String
        let body: String?
        let draft: Bool?
        let state: String?
        let user: User
        let base: Base

        struct User: Codable {
            let login: String
            let avatar_url: String
        }
        struct Base: Codable { let repo: Repo }
        struct Repo: Codable { let full_name: String }
    }
}

struct PRReview: Identifiable {
    let id: Int
    let author: String
    let body: String
    let state: String  // APPROVED, CHANGES_REQUESTED, COMMENTED
    let submittedAt: Date
    let htmlURL: String
}

struct WorkflowRun: Identifiable {
    let id: Int
    let name: String
    let status: String      // completed, in_progress, queued
    let conclusion: String?  // success, failure, cancelled, etc.
    let htmlURL: String
    let createdAt: Date
    var failureMessage: String?  // populated for failed runs
}

struct PRComment: Identifiable {
    let id: Int
    let author: String
    let avatarURL: String
    let body: String
    let createdAt: Date
    let htmlURL: String
    let isBot: Bool
}

struct PRApproval: Hashable {
    let author: String
    let avatarURL: String
}

struct DiffFile: Identifiable {
    let id = UUID()
    let filename: String
    let status: String     // added, modified, removed, renamed
    let additions: Int
    let deletions: Int
    let patch: String?     // unified diff, nil for binary
}
