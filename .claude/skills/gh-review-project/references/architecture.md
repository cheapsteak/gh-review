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
                        GitHub REST + GraphQL API (fetch PRs, diffs, checks, merge, approve)
```

## Relay Server (Cloudflare Worker)

**Runtime:** Cloudflare Workers with Durable Objects (Hibernatable WebSocket API)

### Routes

| Route | Method | Purpose |
|-------|--------|---------|
| `/webhook` | POST | Receives GitHub webhook, verifies signature, broadcasts to clients |
| `/ws?token=<TOKEN>` | GET | WebSocket upgrade, authenticates client |

### Webhook Processing

Handles 3 GitHub event types via `X-GitHub-Event` header:

**`pull_request` events:**
1. Filter to relevant actions: `opened`, `closed`, `synchronize`, `reopened`, `ready_for_review`
2. Extract envelope: `{type: "pr_event", action, pr: {number, title, html_url, created_at, updated_at, user_login, avatar_url, body}, repo: {full_name}}`

**`pull_request_review` events:**
1. Filter to action: `submitted`
2. Extract envelope: `{type: "review_event", action, review: {state, user_login, avatar_url}, pr: {number, title, html_url}, repo: {full_name}}`

**`check_run` events:**
1. Filter to action: `completed`
2. Extract envelope: `{type: "check_run_event", check_run: {name, status, conclusion}, prs: [{number}], repo: {full_name}}`

All envelopes include a `timestamp` field. Forwarded to Durable Object for broadcast.

### Durable Object (WebSocketRoom)

- Single instance keyed by `"default"`
- Uses `this.ctx.acceptWebSocket()` (Hibernatable API) for zero-cost idle
- `webSocketMessage` responds to JSON pings with pongs
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
├── AppDelegate (icon, activation, notification permission + approve action category)
├── AppState (ObservableObject — all shared state)
│   ├── GitHubAPI (actor — REST + GraphQL client)
│   └── WebSocketService (ObservableObject — WebSocket connection)
└── ContentView
    ├── PRToolbarApproveButton (toolbar — approve with hover capsule)
    ├── PRTitleLink (toolbar — clickable repo#number link)
    ├── PRToolbarMergeButtons (toolbar — merge/queue/merge-when-ready)
    ├── PRListView (sidebar — PR list with filters, approve buttons)
    │   ├── PRRowView (individual PR row with approval pills, approve button)
    │   └── ApproveButton (capsule with hover animation)
    ├── PRInfoView (middle — title, description, comments timeline)
    │   └── CommentCardView (individual comment with markdown, bot/review badges)
    └── PRDetailView (right — workflow runs, diff viewer with syntax highlighting)
        ├── DiffFileHeaderView (sticky header with collapse toggle, status icon, +/- counts)
        ├── DiffFileContentView (collapsible file diff with expand threshold)
        └── DiffHighlightedLineView (syntax-highlighted line with diff background)
```

### Data Flow

1. **On launch:** `AppState.refreshPRs()` fetches open PRs from GitHub API for all configured repos
2. **Real-time:** `WebSocketService` connects to relay, receives 3 event types, calls `AppState.handlePREvent()`, `handleReviewEvent()`, or `handleCheckRunEvent()`
3. **Per-PR:** `PRRowView.loadApprovals()` fetches approvals on appear, caches in `AppState.prApprovals`
4. **On select:** `PRInfoView` loads comments + reviews; `PRDetailView` loads diff files + workflow runs + gitattributes patterns; `ContentView` refreshes merge status
5. **Approve:** Calls `GitHubAPI.approvePR()`, updates `AppState.approvedPRs` + `prApprovals` cache, dismisses notification
6. **Review event:** Updates `prApprovals` cache in real-time, refreshes merge status (approval may unblock merge)
7. **Merge:** Direct merge via `GitHubAPI.mergePR()` (squash) or queue via `GitHubAPI.enqueuePR()` (GraphQL mutation)
8. **Merge-when-ready:** Sets `waitingForChecks` state, listens for `check_run` webhook events, auto-enqueues when all checks pass

### Filtering

Filters in `AppState.filteredPullRequests` (applied in order):
1. **Hide closed** (`hideClosed`, default on) — excludes `state == "closed"` or `"merged"`
2. **Hide drafts** (`hideDrafts`, default on) — excludes `isDraft == true`
3. **Needs review** (`needsReviewOnly`, default off) — excludes PRs with human approval (ignoring bot reviewers via `isBot` helper: suffix `[bot]` or contains `longeye-claude-reviewer`)

### Notification Flow

1. WebSocket event arrives with `action == "opened"` for a PR not in the current list and `author != currentUsername`
2. `AppState.handlePREvent()` detects it's new and calls `sendNotification()`
3. Notification uses per-PR identifier (`pr-{repo}-{number}`) for targeted dismiss
4. Category `NEW_PR` with `APPROVE_PR` action button (requires authentication)
5. Clicking notification body: selects PR and focuses app
6. Clicking "Approve" action: calls `appState.approvePR()` silently
7. Approving a PR (from any UI surface) dismisses its notification via `dismissNotification()`
8. If running as `.app` bundle: `UNUserNotificationCenter` (shows app icon)
9. Fallback: `osascript display notification` (shows Script Editor icon)

### Merge Support

**Merge status detection:**
- `fetchMergeStatus()` returns `MergeStatus(mergeable, mergeableState)` via PR detail endpoint
- `blocked` + `mergeable == true` indicates merge queue repository (show "Merge when ready")
- `clean` + `mergeable == true` indicates direct merge possible (show "Merge" button)
- `dirty` indicates conflicts; `mergeable == false` shows "Not mergeable"

**Merge-when-ready system (event-driven via check_run webhooks):**
- `MergeWhenReadyState` enum: `waitingForChecks`, `checksFailed`, `enqueuing`, `enqueued`
- On activation: checks immediately via `fetchChecksStatus()` in case checks already passed
- On `check_run_event`: if conclusion is failure/cancelled/timed_out, marks `checksFailed`; otherwise calls `tryEnqueueIfReady()`
- `ChecksStatus` tracks `total`, `completed`, `passed` (success + skipped + neutral); `allPassed` when all complete and passing
- On all checks passing: transitions to `enqueuing`, calls `enqueuePR()` (GraphQL), transitions to `enqueued`
- Cancel support: removes from `mergeWhenReady` dictionary

**GraphQL merge queue:**
- `fetchPRNodeId()` gets the PR's GraphQL node ID via REST
- `enqueuePR()` calls `enqueuePullRequest` GraphQL mutation with the node ID

### GitHub API Client

`actor GitHubAPI` — thread-safe, async/await. All REST requests include:
- `Authorization: Bearer <PAT>`
- `Accept: application/vnd.github+json`
- `X-GitHub-Api-Version: 2022-11-28`

ISO8601 date parsing with fractional seconds fallback throughout.

**Methods:**

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `fetchCurrentUser` | `GET /user` | Get authenticated username (cached) |
| `fetchOpenPRs` | `GET /repos/{repo}/pulls` | List open PRs (50 per page, sorted by updated) |
| `fetchDiffFiles` | `GET /repos/{repo}/pulls/{n}/files` | Get file diffs for a PR |
| `fetchApprovals` | `GET /repos/{repo}/pulls/{n}/reviews` | Get unique approvers (last state per user) |
| `fetchPRReviews` | `GET /repos/{repo}/pulls/{n}/reviews` | Get reviews filtered to `longeye-claude-reviewer` |
| `fetchWorkflowRuns` | `GET /repos/{repo}/actions/runs?head_sha=` | Workflow runs by PR head SHA |
| `fetchRunFailureMessage` | `GET /repos/{repo}/actions/runs/{id}/jobs` | Failed job + step names |
| `fetchPRComments` | `GET /repos/{repo}/issues/{n}/comments` | Issue comments (100 per page) |
| `fetchChecksStatus` | `GET /repos/{repo}/commits/{sha}/check-runs` | Check run status summary (total/completed/passed) |
| `fetchMergeStatus` | `GET /repos/{repo}/pulls/{n}` | Mergeable state and mergeability |
| `mergePR` | `PUT /repos/{repo}/pulls/{n}/merge` | Direct squash merge |
| `enqueuePR` | `POST /graphql` (mutation) | Add PR to merge queue via GraphQL `enqueuePullRequest` |
| `fetchPRNodeId` | `GET /repos/{repo}/pulls/{n}` | Get PR's GraphQL node_id (private, used by enqueuePR) |
| `fetchGeneratedPatterns` | `GET /repos/{repo}/contents/.gitattributes` | Parse linguist-generated and binary patterns |
| `approvePR` | `POST /repos/{repo}/pulls/{n}/reviews` | Submit APPROVE review |

### Markdown Rendering

`MarkdownWebView` pre-processes markdown to extract `<details><summary>` blocks (via regex), then renders:
- Regular markdown -> `Markdown()` view from swift-markdown-ui with custom `ghReview` theme
- Details blocks -> native `DisclosureGroup` with recursive `MarkdownWebView` for content

### Diff Rendering

- Syntax highlighting via `Highlightr` library with shared instance and "github" theme
- Language detection by file extension (30+ extensions mapped)
- Code content stripped of diff prefixes (+/-/space), highlighted as one block, then reassembled with diff backgrounds
- WCAG luminance check: colors with luminance > 0.6 replaced with label color for readability
- Collapsible files with sticky section headers (`LazyVStack` with `pinnedViews: [.sectionHeaders]`)
- Auto-collapse for generated/binary files based on `.gitattributes` patterns (`linguist-generated`, `binary`)
- Simple glob matching supporting `*` and `**` for gitattributes patterns
- Files >40 lines show first 40 with "Show N more lines" expand button
- Line backgrounds: `+` green, `-` red, `@@` blue, default clear
- File status icons: added (green +), removed (red -), renamed (blue arrow), modified (orange pencil)

### Workflow Runs

- Fetches runs by PR head SHA via `/actions/runs?head_sha=`
- Failed runs: fetches `/actions/runs/{id}/jobs` for failure details (job + step names)
- Display: failed runs expanded with error details, in-progress with spinner, passed/skipped as compact list with status icons
