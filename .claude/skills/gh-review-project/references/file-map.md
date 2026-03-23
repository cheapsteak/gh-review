# File Map

## `app/` — macOS SwiftUI Application

### `app/Sources/`

| File | Purpose |
|------|---------|
| `GHReviewApp.swift` | App entry point (`@main`), `AppDelegate` (icon generation, activation, notification setup), `AppState` (all shared state, PR list, filters, approval caches, WebSocket lifecycle, notification dispatch) |
| `Models.swift` | Data models: `PullRequest`, `PRReview`, `WorkflowRun`, `PRComment`, `PRApproval`, `DiffFile`. Includes `PullRequest.relativeTime()` static formatter and `GitHubResponse` nested struct for API decoding |
| `GitHubAPI.swift` | `actor GitHubAPI` — GitHub REST API client. Methods: `fetchCurrentUser`, `fetchOpenPRs`, `fetchDiffFiles`, `fetchApprovals`, `fetchPRReviews`, `fetchWorkflowRuns`, `fetchRunFailureMessage`, `fetchPRComments`, `approvePR` |
| `WebSocketService.swift` | `WebSocketService` (ObservableObject) — manages `URLSessionWebSocketTask` connection to relay. Recursive receive loop, exponential backoff reconnect, 30s ping keepalive. Decodes relay envelope format into `PullRequest` objects |
| `ContentView.swift` | Root view with 3-column `NavigationSplitView`. Toolbar: PR number link (center), approve button (right). Also defines `PRTitleLink` and `PRToolbarApproveButton` |
| `PRListView.swift` | Sidebar PR list with filters dropdown, refresh button, connection indicator. `PRRowView` shows title, author avatar, time, approval pills, approve button. `ApproveButton` with hover animation |
| `PRInfoView.swift` | Middle column: PR title/author header, markdown description, chronological comment timeline (merged reviews + issue comments). `CommentCardView` and `TimelineItem` for unified display |
| `PRDetailView.swift` | Right column: workflow runs section (failed expanded with details, in-progress with spinner, passed/skipped listed), collapsible diff viewer. `DiffFileView` with 40-line preview threshold, `DiffLineView` with line coloring |
| `SettingsView.swift` | Settings form: GitHub PAT, relay URL, relay token, repos (comma-separated). Stores in UserDefaults |
| `MarkdownWebView.swift` | GFM rendering using swift-markdown-ui. Custom `ghReview` theme (transparent background). Pre-processes `<details><summary>` into `DisclosureGroup`. Color definitions for theme |

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

Single executable target `GHReview`, macOS 14+. Depends on `swift-markdown-ui` (2.0.2+).

## `relay/` — Cloudflare Worker Relay Server

| File | Purpose |
|------|---------|
| `src/index.ts` | Worker entry point + `WebSocketRoom` Durable Object. Webhook verification, PR event extraction, WebSocket upgrade, client broadcast |
| `wrangler.toml` | Worker config: name, compatibility date, Durable Object bindings, SQLite migration |
| `package.json` | Dependencies: wrangler (dev), @cloudflare/workers-types (dev), typescript (dev) |
| `tsconfig.json` | TypeScript config for Workers (ES2022, bundler module resolution) |
