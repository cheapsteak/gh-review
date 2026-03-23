import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.applicationIconImage = createAppIcon()

        // Request notification permission (works when running as .app bundle)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func createAppIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        let context = NSGraphicsContext.current!.cgContext

        // Draw rounded rect background with gradient
        let cornerRadius: CGFloat = 100
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(path)
        context.clip()

        // Blue to purple gradient
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1.0),  // #2563EB
            CGColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1.0)   // #7C3AED
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])

        // Draw PR icon in white
        context.setStrokeColor(CGColor.white)
        context.setFillColor(CGColor.white)
        context.setLineWidth(24)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Main vertical line (right branch)
        let centerX: CGFloat = 290
        let topY: CGFloat = 130
        let bottomY: CGFloat = 380
        context.move(to: CGPoint(x: centerX, y: topY))
        context.addLine(to: CGPoint(x: centerX, y: bottomY))
        context.strokePath()

        // Diagonal merge line (from left)
        let leftX: CGFloat = 190
        let forkY: CGFloat = 200
        context.move(to: CGPoint(x: leftX, y: topY))
        context.addLine(to: CGPoint(x: leftX, y: forkY))
        context.addLine(to: CGPoint(x: centerX, y: forkY + 80))
        context.strokePath()

        // Circles at endpoints
        let circleRadius: CGFloat = 22
        for point in [CGPoint(x: centerX, y: topY), CGPoint(x: centerX, y: bottomY), CGPoint(x: leftX, y: topY)] {
            context.fillEllipse(in: CGRect(x: point.x - circleRadius, y: point.y - circleRadius, width: circleRadius * 2, height: circleRadius * 2))
        }

        // Checkmark in bottom circle to represent "review/approve"
        context.setStrokeColor(CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1.0))
        context.setLineWidth(14)
        let checkX = centerX - 14
        let checkY = bottomY - 4
        context.move(to: CGPoint(x: checkX, y: checkY))
        context.addLine(to: CGPoint(x: checkX + 10, y: checkY - 12))
        context.addLine(to: CGPoint(x: checkX + 28, y: checkY + 14))
        context.strokePath()

        image.unlockFocus()
        return image
    }
}

@main
struct GHReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 700)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var pullRequests: [PullRequest] = []
    @Published var selectedPR: PullRequest?
    @Published var isLoading = false
    @Published var error: String?

    private var gitHubAPI: GitHubAPI?
    let webSocketService = WebSocketService()
    var approvedPRs: Set<String> = []  // "repo#number" keys
    @Published var prApprovals: [String: [PRApproval]] = [:]  // "repo#number" -> approvals
    var currentUsername: String?
    @Published var needsReviewOnly = false
    @Published var hideDrafts = true
    @Published var hideClosed = true

    private func prKey(_ pr: PullRequest) -> String { "\(pr.repo)#\(pr.number)" }

    func markApproved(_ pr: PullRequest) {
        approvedPRs.insert(prKey(pr))
    }

    func isApproved(_ pr: PullRequest) -> Bool {
        approvedPRs.contains(prKey(pr))
    }

    func approvals(for pr: PullRequest) -> [PRApproval] {
        prApprovals[prKey(pr)] ?? []
    }

    func setApprovals(_ approvals: [PRApproval], for pr: PullRequest) {
        prApprovals[prKey(pr)] = approvals
    }

    func hasHumanApproval(_ pr: PullRequest) -> Bool {
        let approvals = approvals(for: pr)
        return approvals.contains { !$0.author.contains("longeye-claude-reviewer") }
    }

    var hasActiveFilters: Bool {
        needsReviewOnly || hideDrafts || hideClosed
    }

    var filteredPullRequests: [PullRequest] {
        var result = pullRequests
        if hideClosed {
            result = result.filter { $0.state != "closed" && $0.state != "merged" }
        }
        if hideDrafts {
            result = result.filter { !$0.isDraft }
        }
        if needsReviewOnly {
            result = result.filter { !hasHumanApproval($0) }
        }
        return result
    }

    // Settings stored in UserDefaults
    var pat: String {
        get { UserDefaults.standard.string(forKey: "github_pat") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "github_pat"); setupAPI() }
    }
    var relayURL: String {
        get { UserDefaults.standard.string(forKey: "relay_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "relay_url") }
    }
    var relayToken: String {
        get { UserDefaults.standard.string(forKey: "relay_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "relay_token") }
    }
    var repos: String {
        get { UserDefaults.standard.string(forKey: "repos") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "repos") }
    }

    var repoList: [String] {
        repos.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    init() {
        setupAPI()
        setupWebSocket()
    }

    func setupAPI() {
        guard !pat.isEmpty else { return }
        gitHubAPI = GitHubAPI(pat: pat)
    }

    func setupWebSocket() {
        webSocketService.onPREvent = { [weak self] action, pr in
            Task { @MainActor in
                self?.handlePREvent(action: action, pr: pr)
            }
        }
    }

    func connectWebSocket() {
        guard !relayURL.isEmpty, !relayToken.isEmpty else { return }
        guard let url = URL(string: "\(relayURL)?token=\(relayToken)") else { return }
        webSocketService.connect(url: url)
    }

    func refreshPRs() async {
        guard let api = gitHubAPI else { return }
        isLoading = true
        error = nil
        var allPRs: [PullRequest] = []
        for repo in repoList {
            do {
                let prs = try await api.fetchOpenPRs(repo: repo)
                allPRs.append(contentsOf: prs)
            } catch {
                self.error = "Failed to fetch PRs for \(repo): \(error.localizedDescription)"
            }
        }
        pullRequests = allPRs.sorted { $0.createdAt > $1.createdAt }
        isLoading = false
    }

    private func handlePREvent(action: String, pr: PullRequest) {
        if action == "closed" {
            // Mark as closed instead of removing, so filter can show/hide
            if let idx = pullRequests.firstIndex(where: { $0.number == pr.number && $0.repo == pr.repo }) {
                var closedPR = pullRequests[idx]
                closedPR = PullRequest(
                    number: closedPR.number, title: closedPR.title, repo: closedPR.repo,
                    author: closedPR.author, avatarURL: closedPR.avatarURL, body: closedPR.body,
                    htmlURL: closedPR.htmlURL, createdAt: closedPR.createdAt, updatedAt: closedPR.updatedAt,
                    isDraft: closedPR.isDraft, state: "closed"
                )
                pullRequests[idx] = closedPR
            }
        } else {
            var newPR = pr
            newPR.isNew = true
            let isNew = !pullRequests.contains(where: { $0.number == pr.number && $0.repo == pr.repo })
            if let idx = pullRequests.firstIndex(where: { $0.number == pr.number && $0.repo == pr.repo }) {
                pullRequests[idx] = newPR
            } else {
                pullRequests.insert(newPR, at: 0)
            }

            if isNew && action == "opened" {
                sendNotification(pr: pr)
            }
        }
    }

    func testNotification() {
        Self.notify(title: "GHReview", subtitle: "Notifications are working", body: "This is a test notification")
    }

    private func sendNotification(pr: PullRequest) {
        Self.notify(title: "New PR", subtitle: pr.title, body: "\(pr.author) opened #\(pr.number) in \(pr.repo)")
        NSApp.requestUserAttention(.informationalRequest)
    }

    static func notify(title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                // Fallback to osascript
                let t = title.replacingOccurrences(of: "\"", with: "\\\"")
                let s = subtitle.replacingOccurrences(of: "\"", with: "\\\"")
                let b = body.replacingOccurrences(of: "\"", with: "\\\"")
                let script = "display notification \"\(b)\" with title \"\(t)\" subtitle \"\(s)\" sound name \"default\""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                try? process.run()
            }
        }
    }
}
