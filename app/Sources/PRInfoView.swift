import SwiftUI

struct PRInfoView: View {
    let pr: PullRequest
    @EnvironmentObject var appState: AppState

    @State private var reviews: [PRReview] = []
    @State private var comments: [PRComment] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // PR title and author
                VStack(alignment: .leading, spacing: 6) {
                    Text(pr.title)
                        .font(.title3)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        AsyncImage(url: URL(string: pr.avatarURL)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.circle.fill").foregroundStyle(.secondary)
                        }
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())

                        Text(pr.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(PullRequest.relativeTime(from: pr.createdAt))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }



                // PR Description section
                VStack(alignment: .leading, spacing: 8) {
                    if pr.body.isEmpty {
                        Text("No description provided.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .italic()
                    } else {
                        MarkdownWebView(markdown: pr.body)
                    }
                }



                // Comments section (reviews + issue comments, chronological)
                VStack(alignment: .leading, spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if reviews.isEmpty && comments.isEmpty {
                        Text("No comments yet.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .italic()
                    } else {
                        // Merge reviews and comments into a unified timeline
                        ForEach(timelineItems) { item in
                            CommentCardView(item: item)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear { loadData() }
        .onChange(of: pr) { loadData() }
    }

    private var timelineItems: [TimelineItem] {
        var items: [TimelineItem] = []

        for review in reviews where !review.body.isEmpty {
            items.append(TimelineItem(
                id: "review-\(review.id)",
                author: review.author,
                avatarURL: "",
                body: review.body,
                date: review.submittedAt,
                htmlURL: review.htmlURL,
                badge: review.state,
                isBot: review.author.contains("[bot]")
            ))
        }

        for comment in comments {
            items.append(TimelineItem(
                id: "comment-\(comment.id)",
                author: comment.author,
                avatarURL: comment.avatarURL,
                body: comment.body,
                date: comment.createdAt,
                htmlURL: comment.htmlURL,
                badge: nil,
                isBot: comment.isBot
            ))
        }

        return items.sorted { $0.date < $1.date }
    }

    private func loadData() {
        reviews = []
        comments = []
        isLoading = true
        let pat = appState.pat
        guard !pat.isEmpty else {
            isLoading = false
            return
        }
        let api = GitHubAPI(pat: pat)
        Task {
            async let fetchedReviews = api.fetchPRReviews(repo: pr.repo, number: pr.number)
            async let fetchedComments = api.fetchPRComments(repo: pr.repo, number: pr.number)

            do {
                reviews = try await fetchedReviews
            } catch {
                print("Failed to load reviews: \(error)")
            }
            do {
                comments = try await fetchedComments
            } catch {
                print("Failed to load comments: \(error)")
            }
            isLoading = false
        }
    }
}

struct TimelineItem: Identifiable {
    let id: String
    let author: String
    let avatarURL: String
    let body: String
    let date: Date
    let htmlURL: String
    let badge: String?  // review state, nil for comments
    let isBot: Bool
}

struct CommentCardView: View {
    let item: TimelineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !item.avatarURL.isEmpty {
                    AsyncImage(url: URL(string: item.avatarURL)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill").foregroundStyle(.secondary)
                    }
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                }

                Text(item.author)
                    .font(.caption)
                    .fontWeight(.medium)

                if item.isBot {
                    Text("bot")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }

                if let badge = item.badge {
                    reviewStateBadge(badge)
                }

                Spacer()

                Text(PullRequest.relativeTime(from: item.date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !item.body.isEmpty {
                MarkdownWebView(markdown: item.body)
            }

            if let url = URL(string: item.htmlURL) {
                Link("View on GitHub", destination: url)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func reviewStateBadge(_ state: String) -> some View {
        let (text, color): (String, Color) = switch state {
        case "APPROVED": ("Approved", .green)
        case "CHANGES_REQUESTED": ("Changes Requested", .red)
        default: ("Commented", .blue)
        }
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
