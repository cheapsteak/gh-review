# File Map

## `app/` — macOS SwiftUI Application

### `app/Sources/`

| File | Purpose |
|------|---------|
| `GHReviewApp.swift` | App entry point (`@main`), `AppDelegate` (icon generation, activation, notification setup with approve action + per-PR IDs), `AppState` (all shared state, PR list, filters, approval caches, merge status, merge-when-ready system, WebSocket lifecycle, notification dispatch with dismiss-on-approve) |
| `Models.swift` | Data models: `PullRequest`, `PRReview`, `WorkflowRun`, `PRComment`, `PRApproval`, `DiffFile`. Includes `PullRequest.relativeTime()` static formatter and `GitHubResponse` nested struct for API decoding |
| `GitHubAPI.swift` | `actor GitHubAPI` — GitHub REST + GraphQL API client. Methods: `fetchCurrentUser`, `fetchOpenPRs`, `fetchDiffFiles`, `fetchApprovals`, `fetchPRReviews`, `fetchWorkflowRuns`, `fetchRunFailureMessage`, `fetchPRComments`, `fetchChecksStatus`, `fetchMergeStatus`, `mergePR`, `enqueuePR` (GraphQL mutation via `fetchPRNodeId`), `fetchGeneratedPatterns`, `approvePR`. Includes `MergeStatus` and `ChecksStatus` structs |
| `WebSocketService.swift` | `WebSocketService` (ObservableObject) — manages `URLSessionWebSocketTask` connection to relay. Decodes 3 event types: `pr_event` (default), `review_event`, `check_run_event`. Callbacks: `onPREvent`, `onReviewEvent`, `onCheckRunEvent`. Recursive receive loop, exponential backoff reconnect, 30s ping keepalive |
| `ContentView.swift` | Root view with 3-column `NavigationSplitView`. Toolbar: approve button (left), PR number link (center), merge/queue buttons (right). Defines `PRTitleLink`, `PRToolbarApproveButton`, `PRToolbarMergeButtons` (merge queue detection, merge-when-ready states), `ActionCapsuleButton`. Refreshes merge status on PR selection |
| `PRListView.swift` | Sidebar PR list with filters dropdown, refresh button, test notification button, connection indicator. `PRRowView` shows title, author avatar, time, human-approval checkmark, approve button (hidden for own PRs), approval pills. `ApproveButton` with hover animation |
| `PRInfoView.swift` | Middle column: PR title/author header, markdown description, chronological comment timeline (merged reviews + issue comments). `CommentCardView` with bot badges and review state badges. `TimelineItem` for unified display. Reviews filtered to `longeye-claude-reviewer` only |
| `PRDetailView.swift` | Right column: workflow runs section, diff viewer with syntax highlighting (Highlightr), collapsible files with sticky section headers, gitattributes-based auto-collapse for generated/binary files. `DiffFileHeaderView` (status icons, +/- counts), `DiffFileContentView` (40-line preview threshold), `DiffHighlightedLineView`. Shared `Highlightr` instance with "github" theme, language detection by file extension, WCAG luminance enforcement for pale colors |
| `SettingsView.swift` | Settings form: GitHub PAT, relay URL, relay token, repos (comma-separated). Stores in UserDefaults |
| `MarkdownWebView.swift` | GFM rendering using swift-markdown-ui. Custom `ghReview` theme (transparent background, 13pt base). Pre-processes `<details><summary>` into `DisclosureGroup`. Color definitions for light/dark mode |

### `app/Resources/`

| File | Purpose |
|------|---------|
| `Info.plist` | App bundle metadata: bundle ID (`com.gh-review.app`), icon reference, version |
| `AppIcon.icns` | App icon in all required sizes (16–1024px). Blue-to-purple gradient with PR merge symbol and checkmark |

### `app/scripts/`

| File | Purpose |
|------|---------|
| `build-app.sh` | Builds release binary, assembles `.app` bundle, ad-hoc code signs |
| `generate-icns.swift` | Generates `AppIcon.icns` from programmatic Core Graphics drawing |

### `app/Package.swift`

Single executable target `GHReview`, macOS 14+. Depends on `swift-markdown-ui` (2.0.2+) and `Highlightr` (2.2.1+).

## `relay/` — Cloudflare Worker Relay Server

| File | Purpose |
|------|---------|
| `src/index.ts` | Worker entry point + `WebSocketRoom` Durable Object. Handles 3 GitHub event types: `pull_request` (5 actions), `pull_request_review` (submitted), `check_run` (completed). Webhook signature verification, typed envelope extraction, WebSocket upgrade, client broadcast |
| `wrangler.toml` | Worker config: name, compatibility date, Durable Object bindings, SQLite migration |
| `package.json` | Dependencies: wrangler (dev), @cloudflare/workers-types (dev), typescript (dev) |
| `tsconfig.json` | TypeScript config for Workers (ES2022, bundler module resolution) |
