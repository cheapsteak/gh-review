# Architecture

## System Overview

```
GitHub ──webhook POST──▸ Cloudflare Worker
                             │
                        Durable Object (WebSocketRoom)
                             │
                        WebSocket connection
                             │
                        macOS SwiftUI App
                             │
                        GitHub REST API (fetch PRs, diffs, approve)
```

## Relay Server (Cloudflare Worker)

**Runtime:** Cloudflare Workers with Durable Objects (Hibernatable WebSocket API)

### Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/webhook` | POST | Receives GitHub webhook, verifies signature, broadcasts to clients |
| `/ws?token=<TOKEN>` | GET | WebSocket upgrade, authenticates client |

### Webhook Processing

1. Verify `X-Hub-Signature-256` using HMAC SHA-256 with `WEBHOOK_SECRET`
2. Filter to relevant PR actions: `opened`, `closed`, `synchronize`, `reopened`, `ready_for_review`
3. Extract slim envelope: `{action, pr: {number, title, html_url, created_at, updated_at, user_login, avatar_url, body}, repo: {full_name}}`
4. Forward to Durable Object for broadcast

### Durable Object (WebSocketRoom)

- Single instance keyed by `"default"`
- Uses `this.ctx.acceptWebSocket()` (Hibernatable API) for zero-cost idle
- `webSocketMessage` responds to pings
- `webSocketClose`/`webSocketError` for cleanup
- `broadcast()` sends to all connected clients via `this.ctx.getWebSockets()`

### Secrets

| Name | Purpose |
|------|---------|
| `WEBHOOK_SECRET` | Validates GitHub webhook signatures |
| `AUTH_TOKEN` | Authenticates WebSocket client connections |

## macOS App (SwiftUI)

### Component Hierarchy

```
GHReviewApp (@main)
├── AppDelegate (icon, activation, notification permission)
├── AppState (ObservableObject — all shared state)
│   ├── GitHubAPI (actor — REST client)
│   └── WebSocketService (ObservableObject — WebSocket connection)
└── ContentView
    ├── PRListView (sidebar — PR list with filters, approve buttons)
    │   └── PRRowView (individual PR row with approval pills)
    ├── PRInfoView (middle — title, description, comments timeline)
    │   └── CommentCardView (individual comment with markdown)
    └── PRDetailView (right — workflow runs, diff viewer)
        └── DiffFileView (collapsible file diff with line coloring)
```

### Data Flow

1. **On launch:** `AppState.refreshPRs()` fetches open PRs from GitHub API for all configured repos
2. **Real-time:** `WebSocketService` connects to relay, receives PR events, calls `AppState.handlePREvent()`
3. **Per-PR:** `PRRowView.loadApprovals()` fetches approvals on appear, caches in `AppState.prApprovals`
4. **On select:** `PRInfoView` loads comments + reviews; `PRDetailView` loads diff files + workflow runs
5. **Approve:** Calls `GitHubAPI.approvePR()`, updates `AppState.approvedPRs` + `prApprovals` cache

### Filtering

Filters in `AppState.filteredPullRequests` (applied in order):
1. **Hide closed** (`hideClosed`, default on) — excludes `state == "closed"` or `"merged"`
2. **Hide drafts** (`hideDrafts`, default on) — excludes `isDraft == true`
3. **Needs review** (`needsReviewOnly`, default off) — excludes PRs with human approval (ignoring bot reviewers matching `longeye-claude-reviewer`)

### Notification Flow

1. WebSocket event arrives with `action == "opened"` for a PR not in the current list
2. `AppState.handlePREvent()` detects it's new and calls `sendNotification()`
3. If running as `.app` bundle: `UNUserNotificationCenter` (shows app icon)
4. Fallback: `osascript display notification` (shows Script Editor icon)

### GitHub API Client

`actor GitHubAPI` — thread-safe, async/await. All requests include:
- `Authorization: Bearer <PAT>`
- `Accept: application/vnd.github+json`
- `X-GitHub-Api-Version: 2022-11-28`

ISO8601 date parsing with fractional seconds fallback throughout.

### Markdown Rendering

`MarkdownWebView` pre-processes markdown to extract `<details><summary>` blocks (via regex), then renders:
- Regular markdown → `Markdown()` view from swift-markdown-ui with custom `ghReview` theme
- Details blocks → native `DisclosureGroup` with recursive `MarkdownWebView` for content

### Diff Rendering

- Files >40 lines show first 40 with "Show N more lines" expand button
- Line coloring: `+` green, `-` red, `@@` blue, default clear
- Monospaced font, full-width lines

### Workflow Runs

- Fetches runs by PR head SHA via `/actions/runs?head_sha=`
- Failed runs: fetches `/actions/runs/{id}/jobs` for failure details (job + step names)
- Display: failed runs expanded with error details, in-progress with spinner, passed/skipped as compact list
