---
name: gh-review-project
description: GH Review project knowledge — architecture, components, and conventions. Use when working on the GH Review codebase, adding features, fixing bugs, or understanding how the system works. Triggers on questions about the macOS app, relay server, WebSocket connection, GitHub API integration, or PR review workflow.
---

# GH Review Project Guide

GH Review is a macOS native desktop app for reviewing GitHub pull requests in real-time. Two components: a Cloudflare Worker relay server and a SwiftUI macOS app.

## Architecture

GitHub sends webhook events to the relay server, which broadcasts them to connected desktop clients via WebSocket. The app also calls the GitHub REST API directly for fetching PR data, diffs, and submitting approvals.

```
GitHub ──webhook──▸ Cloudflare Worker (relay)
                        │
                   WebSocket (Durable Object)
                        │
                   macOS SwiftUI app ──REST API──▸ GitHub
```

For detailed architecture and file descriptions: consult `references/architecture.md`

For a map of key files and what they do: consult `references/file-map.md`

## Key Conventions

### Swift Package Structure

Single executable target `GHReview`. macOS 14+ deployment target. Dependencies: `swift-markdown-ui` (2.0.2+) for GFM rendering, `Highlightr` (2.2.1+) for syntax highlighting in diffs.

### .app Bundle

The app is built as a proper `.app` bundle via `scripts/build-app.sh`:
1. `swift build -c release` compiles the binary
2. Script assembles `GHReview.app/Contents/` with binary, Info.plist, AppIcon.icns
3. Ad-hoc code signing for `UNUserNotificationCenter` support

For development, `swift run` also works (falls back to osascript for notifications).

### GitHub API

All requests use `actor GitHubAPI` with async/await. Auth via classic PAT with `Bearer` token. The actor caches the current username after first `/user` call.

Key endpoints used:
- `GET /repos/{repo}/pulls` — list open PRs
- `GET /repos/{repo}/pulls/{number}` — merge status, node_id, head SHA
- `GET /repos/{repo}/pulls/{number}/files` — get diff
- `POST /repos/{repo}/pulls/{number}/reviews` — approve PR
- `GET /repos/{repo}/pulls/{number}/reviews` — get approvals / reviews
- `PUT /repos/{repo}/pulls/{number}/merge` — direct squash merge
- `GET /repos/{repo}/issues/{number}/comments` — get PR comments
- `GET /repos/{repo}/actions/runs` — workflow runs by commit SHA
- `GET /repos/{repo}/actions/runs/{id}/jobs` — failure details
- `GET /repos/{repo}/commits/{sha}/check-runs` — check run status summary
- `GET /repos/{repo}/contents/.gitattributes` — linguist-generated patterns
- `POST /graphql` — `enqueuePullRequest` mutation for merge queue

### Relay Server

Cloudflare Worker with a single Durable Object (`WebSocketRoom`) using the Hibernatable WebSocket API. Two routes:
- `POST /webhook` — verifies `X-Hub-Signature-256`, handles 3 event types (`pull_request`, `pull_request_review`, `check_run`), extracts typed envelope, broadcasts to clients
- `GET /ws?token=<TOKEN>` — authenticates and upgrades to WebSocket

Secrets (`WEBHOOK_SECRET`, `AUTH_TOKEN`) are set via `wrangler secret put`.

### State Management

`AppState` (ObservableObject) owns all shared state:
- `pullRequests` — fetched from API, updated by WebSocket events
- `prApprovals` — cached per PR, keyed by `"repo#number"`
- `approvedPRs` — set of PRs the current user has approved
- `currentUsername` — cached after first API call
- `mergeStatus` — per-PR `MergeStatus` (mergeable, mergeableState)
- `mergeQueued` — set of PRs added to merge queue
- `mergeWhenReady` — per-PR `MergeWhenReadyState` (waitingForChecks, checksFailed, enqueuing, enqueued)
- Filter states: `needsReviewOnly`, `hideDrafts`, `hideClosed`
- WebSocket callbacks: `onPREvent`, `onReviewEvent`, `onCheckRunEvent`
- Bot detection: `isBot()` helper (suffix `[bot]` or contains `longeye-claude-reviewer`)

Settings (PAT, relay URL, relay token, repos) stored in `UserDefaults`.

### Markdown Rendering

Uses `swift-markdown-ui` with a custom `ghReview` theme (transparent background, 13pt base font). HTML `<details><summary>` blocks are pre-processed into native SwiftUI `DisclosureGroup` views via regex parsing before passing to MarkdownUI.

### Notifications

Uses `UNUserNotificationCenter` when running as `.app` bundle (with bundle ID + code signing). Falls back to `osascript display notification` when running via `swift run`. Notifications use per-PR identifiers (`pr-{repo}-{number}`) for targeted dismiss. Category `NEW_PR` with `APPROVE_PR` action button. Approving from any surface dismisses the notification. Own PRs are suppressed (`author != currentUsername`).

## Common Tasks

### Build and run (development)
```bash
cd app && swift run
```

### Build .app bundle (production)
```bash
cd app && bash scripts/build-app.sh && open build/GHReview.app
```

### Deploy relay server
```bash
cd relay && npm install && npx wrangler deploy
```

### Set relay secrets
```bash
cd relay && npx wrangler secret put WEBHOOK_SECRET
cd relay && npx wrangler secret put AUTH_TOKEN
```

### Regenerate app icon
```bash
swift app/scripts/generate-icns.swift
```
