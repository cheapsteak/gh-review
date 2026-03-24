import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.applicationIconImage = createAppIcon()

        // Request notification permission and register approve action
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let approveAction = UNNotificationAction(identifier: "APPROVE_PR", title: "Approve", options: [.authenticationRequired])
        let prCategory = UNNotificationCategory(identifier: "NEW_PR", actions: [approveAction], intentIdentifiers: [])
        center.setNotificationCategories([prCategory])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let repo = userInfo["repo"] as? String, let number = userInfo["number"] as? Int {
            if response.actionIdentifier == "APPROVE_PR" {
                // Approve silently without changing app state
                Task { @MainActor in
                    await appState?.approvePR(repo: repo, number: number)
                }
            } else {
                // Clicked the notification body — select PR and focus app
                Task { @MainActor in
                    if let pr = appState?.pullRequests.first(where: { $0.repo == repo && $0.number == number }) {
                        appState?.selectedPR = pr
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        completionHandler()
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
                .onAppear { appDelegate.appState = appState }
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
    @Published var mergeStatus: [String: GitHubAPI.MergeStatus] = [:]  // "repo#number" -> status
    @Published var needsReviewOnly = false
    @Published var hideDrafts = true
    @Published var hideClosed = true

    private func prKey(_ pr: PullRequest) -> String { "\(pr.repo)#\(pr.number)" }

    func markApproved(_ pr: PullRequest) {
        approvedPRs.insert(prKey(pr))
        dismissNotification(repo: pr.repo, number: pr.number)
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

    func approvePR(repo: String, number: Int) async {
        guard !pat.isEmpty else { return }
        let api = GitHubAPI(pat: pat)
        do {
            try await api.approvePR(repo: repo, number: number)
            let user = try await api.fetchCurrentUser()
            let key = "\(repo)#\(number)"
            approvedPRs.insert(key)
            var current = prApprovals[key] ?? []
            if !current.contains(where: { $0.author == user }) {
                current.append(PRApproval(author: user, avatarURL: ""))
                prApprovals[key] = current
            }
            dismissNotification(repo: repo, number: number)
        } catch {}
    }

    func dismissNotification(repo: String, number: Int) {
        let id = "pr-\(repo)-\(number)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
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
        webSocketService.onReviewEvent = { [weak self] repo, number, state, login, avatarURL in
            Task { @MainActor in
                self?.handleReviewEvent(repo: repo, number: number, state: state, login: login, avatarURL: avatarURL)
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

    private func handleReviewEvent(repo: String, number: Int, state: String, login: String, avatarURL: String?) {
        let key = "\(repo)#\(number)"
        if state == "approved" {
            var current = prApprovals[key] ?? []
            if !current.contains(where: { $0.author == login }) {
                current.append(PRApproval(author: login, avatarURL: avatarURL ?? ""))
                prApprovals[key] = current
            }
            // Refresh merge status since approval may unblock merge
            Task {
                await refreshMergeStatus(repo: repo, number: number)
            }
        }
    }

    func refreshMergeStatus(repo: String, number: Int) async {
        guard let api = gitHubAPI else { return }
        let key = "\(repo)#\(number)"
        do {
            let status = try await api.fetchMergeStatus(repo: repo, number: number)
            mergeStatus[key] = status
        } catch {}
    }

    @Published var mergeQueued: Set<String> = []  // "repo#number" keys for PRs in merge queue

    func mergePR(repo: String, number: Int) async {
        guard let api = gitHubAPI else { return }
        do {
            try await api.mergePR(repo: repo, number: number)
            let key = "\(repo)#\(number)"
            mergeQueued.insert(key)
        } catch {}
    }

    private func sendNotification(pr: PullRequest) {
        let content = UNMutableNotificationContent()
        content.title = "New PR"
        content.subtitle = pr.title
        content.body = "\(pr.author) opened #\(pr.number) in \(pr.repo)"
        content.sound = .default
        content.categoryIdentifier = "NEW_PR"
        content.userInfo = ["repo": pr.repo, "number": pr.number]
        let notificationID = "pr-\(pr.repo)-\(pr.number)"
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                Self.osascriptNotify(title: "New PR", subtitle: pr.title, body: "\(pr.author) opened #\(pr.number) in \(pr.repo)")
            }
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    func testNotification() {
        Self.notify(title: "GHReview", subtitle: "Notifications are working", body: "This is a test notification")
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
                osascriptNotify(title: title, subtitle: subtitle, body: body)
            }
        }
    }

    private static func osascriptNotify(title: String, subtitle: String, body: String) {
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
