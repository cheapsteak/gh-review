import Foundation
import Combine

class WebSocketService: ObservableObject {
    @Published var isConnected = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private var pingTimer: Timer?
    private var currentURL: URL?

    var onPREvent: ((String, PullRequest) -> Void)?
    var onReviewEvent: ((String, Int, String, String, String?) -> Void)?  // (repo, number, state, login, avatarURL)
    var onCheckRunEvent: ((String, [Int], String, String?) -> Void)?  // (repo, prNumbers, status, conclusion)

    func connect(url: URL) {
        disconnect()
        currentURL = url
        reconnectDelay = 1.0

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        DispatchQueue.main.async {
            self.isConnected = true
        }

        receiveMessage()
        startPingTimer()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.decodeMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.decodeMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure:
                DispatchQueue.main.async {
                    self.isConnected = false
                }
                self.scheduleReconnect()
            }
        }
    }

    private func decodeMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // Check event type first
        struct TypeCheck: Codable { let type: String? }
        let typeCheck = try? JSONDecoder().decode(TypeCheck.self, from: data)

        switch typeCheck?.type {
        case "review_event":
            decodeReviewEvent(data)
        case "check_run_event":
            decodeCheckRunEvent(data)
        default:
            decodePREvent(data)
        }
    }

    private func decodeCheckRunEvent(_ data: Data) {
        struct WSCheckRunMessage: Codable {
            let check_run: CheckRunData
            let prs: [PRRef]
            let repo: RepoData

            struct CheckRunData: Codable {
                let name: String
                let status: String
                let conclusion: String?
            }
            struct PRRef: Codable { let number: Int }
            struct RepoData: Codable { let full_name: String? }
        }

        guard let message = try? JSONDecoder().decode(WSCheckRunMessage.self, from: data) else { return }
        let repo = message.repo.full_name ?? ""
        let prNumbers = message.prs.map(\.number)
        DispatchQueue.main.async {
            self.onCheckRunEvent?(repo, prNumbers, message.check_run.status, message.check_run.conclusion)
        }
    }

    private func decodeReviewEvent(_ data: Data) {
        struct WSReviewMessage: Codable {
            let review: ReviewData
            let pr: PRRef
            let repo: RepoData

            struct ReviewData: Codable {
                let state: String
                let user_login: String?
                let avatar_url: String?
            }
            struct PRRef: Codable { let number: Int }
            struct RepoData: Codable { let full_name: String? }
        }

        guard let message = try? JSONDecoder().decode(WSReviewMessage.self, from: data) else { return }
        let repo = message.repo.full_name ?? ""
        DispatchQueue.main.async {
            self.onReviewEvent?(repo, message.pr.number, message.review.state, message.review.user_login ?? "", message.review.avatar_url)
        }
    }

    private func decodePREvent(_ data: Data) {
        struct WSMessage: Codable {
            let action: String
            let pr: PRData
            let repo: RepoData

            struct PRData: Codable {
                let number: Int
                let title: String
                let html_url: String
                let created_at: String?
                let updated_at: String?
                let user_login: String?
                let avatar_url: String?
                let body: String?
            }
            struct RepoData: Codable {
                let full_name: String?
            }
        }

        guard let message = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String?) -> Date {
            guard let str else { return Date() }
            return formatter.date(from: str) ?? fallback.date(from: str) ?? Date()
        }

        let pr = PullRequest(
            number: message.pr.number,
            title: message.pr.title,
            repo: message.repo.full_name ?? "",
            author: message.pr.user_login ?? "",
            avatarURL: message.pr.avatar_url ?? "",
            body: message.pr.body ?? "",
            htmlURL: message.pr.html_url,
            createdAt: parseDate(message.pr.created_at),
            updatedAt: parseDate(message.pr.updated_at),
            isDraft: false,
            state: "open"
        )

        DispatchQueue.main.async {
            self.onPREvent?(message.action, pr)
        }
    }

    private func scheduleReconnect() {
        guard let url = currentURL else { return }
        let delay = reconnectDelay

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.connect(url: url)
        }

        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func sendPing() {
        webSocketTask?.sendPing { error in
            if error != nil {
                DispatchQueue.main.async {
                    self.isConnected = false
                }
            }
        }
    }
}
