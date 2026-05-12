# Author Rail Quick Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 44pt-wide vertical author rail to the left of the PR list in the sidebar. Top "All" button + up to 9 author avatars ordered by recent PR activity. Single-select with pinned-selection behavior so the active filter is always visible.

**Architecture:** All work lives in the existing macOS Swift app at `/Users/chang/projects/gh-review/app/`. Filter state and the recency-ordered author list live on `AppState` (`GHReviewApp.swift`). The rail view and its subviews live in `PRListView.swift`. A small `AuthorRailEntry` value type lives in `Models.swift`. The rail is composed into the sidebar by wrapping the existing list body in an `HStack { AuthorRailView; Divider; ExistingList }`.

**Tech Stack:** SwiftUI, macOS 14+, Swift Package Manager. No test target exists in this project, so this plan uses **build + manual smoke verification** instead of XCTest. Each task ends with `swift build` (must succeed) and a commit. The final task additionally rebuilds the `.app` bundle and launches it for visual verification.

**Spec reference:** `docs/superpowers/specs/2026-05-12-author-rail-quick-filter-design.md`

---

## File Structure

| File | Role | Change |
|---|---|---|
| `app/Sources/Models.swift` | Plain data structs | Add `AuthorRailEntry` |
| `app/Sources/GHReviewApp.swift` | `AppState`, app entry, filter logic | Add `selectedAuthor`, `lastSeenAvatarURL`, `authorsByRecency`; update `hasActiveFilters` + `filteredPullRequests` |
| `app/Sources/PRListView.swift` | Sidebar views | Add `AuthorRailView`, `AllAuthorsButton`, `AuthorAvatarButton`; wrap body in `HStack` |

No new files.

---

## Task 1: AppState — data types, state, filter integration

**Files:**
- Modify: `app/Sources/Models.swift` — append `AuthorRailEntry` struct at end of file
- Modify: `app/Sources/GHReviewApp.swift` — add fields to `AppState`, update filter computed properties

### Step 1.1: Add `AuthorRailEntry` to Models.swift

Append at the bottom of `app/Sources/Models.swift` (after `DiffFile`):

```swift
struct AuthorRailEntry: Hashable, Identifiable {
    let username: String
    let avatarURL: String
    var id: String { username }
}
```

### Step 1.2: Add `selectedAuthor` and `lastSeenAvatarURL` to `AppState`

In `app/Sources/GHReviewApp.swift`, locate the `@Published` block in `AppState` (around line 151–154). Add `selectedAuthor` after `hideClosed`, and add the `pullRequests` `didSet` hook.

Replace this block:

```swift
    @Published var pullRequests: [PullRequest] = []
    @Published var selectedPR: PullRequest?
    @Published var isLoading = false
    @Published var error: String?
```

With:

```swift
    @Published var pullRequests: [PullRequest] = [] {
        didSet { recordAvatars(from: pullRequests) }
    }
    @Published var selectedPR: PullRequest?
    @Published var isLoading = false
    @Published var error: String?
```

And replace this block (currently around lines 151–154):

```swift
    @Published var needsReviewOnly = false
    @Published var myPRsOnly = false
    @Published var hideDrafts = true
    @Published var hideClosed = true
```

With:

```swift
    @Published var needsReviewOnly = false
    @Published var myPRsOnly = false
    @Published var hideDrafts = true
    @Published var hideClosed = true
    @Published var selectedAuthor: String? = nil

    /// Most recent avatar URL we've seen for each author. Lets the rail still
    /// render the selected author's avatar even if their PRs roll off the list.
    private var lastSeenAvatarURL: [String: String] = [:]
```

### Step 1.3: Add `recordAvatars` and `authorsByRecency`

Add these two members to `AppState`. Place them immediately above `var hasActiveFilters: Bool` (currently around line 208).

```swift
    private func recordAvatars(from prs: [PullRequest]) {
        for pr in prs {
            lastSeenAvatarURL[pr.author] = pr.avatarURL
        }
    }

    /// Up to 9 authors. Ordered by their most-recent PR (`updatedAt`,
    /// falling back to `createdAt`). If `selectedAuthor` is outside the
    /// top 9, it gets pinned as the 9th entry so the active filter is
    /// always represented in the rail.
    var authorsByRecency: [AuthorRailEntry] {
        // Group PRs by author, keep the latest activity timestamp per author.
        var latest: [String: Date] = [:]
        var avatar: [String: String] = [:]
        for pr in pullRequests {
            let activity = max(pr.updatedAt, pr.createdAt)
            if let existing = latest[pr.author] {
                if activity > existing {
                    latest[pr.author] = activity
                    avatar[pr.author] = pr.avatarURL
                }
            } else {
                latest[pr.author] = activity
                avatar[pr.author] = pr.avatarURL
            }
        }

        let sorted = latest.sorted { $0.value > $1.value }.map { $0.key }
        let top9 = Array(sorted.prefix(9))

        // Default: top 9 as-is.
        var chosen = top9

        // Pin selection if it's outside the top 9 (or absent entirely).
        if let selected = selectedAuthor, !chosen.contains(selected) {
            chosen = Array(top9.prefix(8))
            chosen.append(selected)
        }

        return chosen.map { username in
            let url = avatar[username] ?? lastSeenAvatarURL[username] ?? ""
            return AuthorRailEntry(username: username, avatarURL: url)
        }
    }
```

### Step 1.4: Update `hasActiveFilters` and `filteredPullRequests`

Replace this block (around line 208):

```swift
    var hasActiveFilters: Bool {
        needsReviewOnly || hideDrafts || hideClosed || myPRsOnly
    }
```

With:

```swift
    var hasActiveFilters: Bool {
        needsReviewOnly || hideDrafts || hideClosed || myPRsOnly || selectedAuthor != nil
    }
```

Then locate the existing `filteredPullRequests` (around lines 212–231) and add a new clause at the end of the filter chain. Replace:

```swift
    var filteredPullRequests: [PullRequest] {
        var result = pullRequests
        let hidden = hiddenAuthorList
        if !hidden.isEmpty {
            result = result.filter { !hidden.contains($0.author.lowercased()) }
        }
        if hideClosed {
            result = result.filter { $0.state != "closed" && $0.state != "merged" }
        }
        if hideDrafts {
            result = result.filter { !$0.isDraft }
        }
        if needsReviewOnly {
            result = result.filter { !hasHumanApproval($0) }
        }
        if myPRsOnly {
            result = result.filter { $0.author == currentUsername }
        }
        return result
    }
```

With:

```swift
    var filteredPullRequests: [PullRequest] {
        var result = pullRequests
        let hidden = hiddenAuthorList
        if !hidden.isEmpty {
            result = result.filter { !hidden.contains($0.author.lowercased()) }
        }
        if hideClosed {
            result = result.filter { $0.state != "closed" && $0.state != "merged" }
        }
        if hideDrafts {
            result = result.filter { !$0.isDraft }
        }
        if needsReviewOnly {
            result = result.filter { !hasHumanApproval($0) }
        }
        if myPRsOnly {
            result = result.filter { $0.author == currentUsername }
        }
        if let selectedAuthor {
            result = result.filter { $0.author == selectedAuthor }
        }
        return result
    }
```

### Step 1.5: Build to verify

Run from the repo root:

```bash
cd /Users/chang/projects/gh-review/app && swift build
```

Expected: `Build complete!` with no errors. Warnings are acceptable.

### Step 1.6: Commit

```bash
cd /Users/chang/projects/gh-review
git add app/Sources/Models.swift app/Sources/GHReviewApp.swift
git commit -m "feat(app-state): add author filter state and ordered authors-by-recency"
```

---

## Task 2: Add rail views (no integration yet)

**Files:**
- Modify: `app/Sources/PRListView.swift` — append three new `View` structs at the end of file. **Do not** modify `PRListView.body` yet.

### Step 2.1: Append `AuthorRailView`, `AllAuthorsButton`, `AuthorAvatarButton` to `PRListView.swift`

Append at the end of `app/Sources/PRListView.swift` (after the closing brace of `ApproveButton`):

```swift
// MARK: - Author Rail

private let authorRailWidth: CGFloat = 44
private let authorRailAvatarSize: CGFloat = 28
private let authorRailSelectionRingWidth: CGFloat = 2

struct AuthorRailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                AllAuthorsButton(
                    isSelected: appState.selectedAuthor == nil,
                    action: { appState.selectedAuthor = nil }
                )

                ForEach(appState.authorsByRecency) { entry in
                    AuthorAvatarButton(
                        entry: entry,
                        isSelected: appState.selectedAuthor == entry.username,
                        action: { appState.selectedAuthor = entry.username }
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: authorRailWidth)
    }
}

struct AllAuthorsButton: View {
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: authorRailAvatarSize, height: authorRailAvatarSize)
                .background(
                    Circle().fill(isHovered ? Color.secondary.opacity(0.15) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    Circle().stroke(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: authorRailSelectionRingWidth
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("All authors")
    }
}

struct AuthorAvatarButton: View {
    let entry: AuthorRailEntry
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            AsyncImage(url: URL(string: entry.avatarURL)) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: authorRailAvatarSize, height: authorRailAvatarSize)
            .clipShape(Circle())
            .background(
                Circle().fill(isHovered ? Color.secondary.opacity(0.15) : Color.clear)
            )
            .overlay(
                Circle().stroke(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: authorRailSelectionRingWidth
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(entry.username)
    }
}
```

### Step 2.2: Build to verify

```bash
cd /Users/chang/projects/gh-review/app && swift build
```

Expected: `Build complete!`. The new views are not referenced yet, so the build will succeed without rendering them.

### Step 2.3: Commit

```bash
cd /Users/chang/projects/gh-review
git add app/Sources/PRListView.swift
git commit -m "feat(ui): add AuthorRailView and avatar/all buttons"
```

---

## Task 3: Wire rail into the sidebar

**Files:**
- Modify: `app/Sources/PRListView.swift` — change `PRListView.body` to wrap existing content in `HStack { AuthorRailView; Divider; ExistingList }`.

### Step 3.1: Wrap `PRListView.body` content

In `app/Sources/PRListView.swift`, replace the entire `var body: some View { ... }` of `PRListView` (currently lines 6–77). The existing body contains a `Group { ... }` followed by `.overlay` and `.toolbar`. We will keep the `Group`, `.overlay`, and `.toolbar` exactly as they are — they become the right-hand side of a new `HStack`.

Replace:

```swift
    var body: some View {
        Group {
            if appState.isLoading && appState.pullRequests.isEmpty {
                ProgressView("Loading pull requests...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.pullRequests.isEmpty {
                VStack(spacing: 8) {
                    Text("No pull requests")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Configure repos in Settings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.filteredPullRequests, selection: $appState.selectedPR) { pr in
                    PRRowView(pr: pr)
                        .tag(pr)
                }
                .listStyle(.sidebar)
                .onChange(of: appState.selectedPR) { _, newPR in
                    guard let pr = newPR, pr.isNew,
                          let idx = appState.pullRequests.firstIndex(where: { $0.id == pr.id }) else { return }
                    appState.pullRequests[idx].isNew = false
                    appState.selectedPR = appState.pullRequests[idx]
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = appState.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Toggle("Only my PRs", isOn: $appState.myPRsOnly)
                    Toggle("Needs review", isOn: $appState.needsReviewOnly)
                    Toggle("Hide drafts", isOn: $appState.hideDrafts)
                    Toggle("Hide closed", isOn: $appState.hideClosed)
                } label: {
                    Image(systemName: appState.hasActiveFilters
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("Filter pull requests")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await appState.refreshPRs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(appState.isLoading)
                .help("Refresh pull requests")
            }

            ToolbarItem(placement: .automatic) {
                Circle()
                    .fill(appState.webSocketService.isConnected ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .help(appState.webSocketService.isConnected ? "Live updates connected" : "Live updates disconnected")
            }
        }
    }
```

With:

```swift
    var body: some View {
        HStack(spacing: 0) {
            AuthorRailView()

            Divider()

            Group {
                if appState.isLoading && appState.pullRequests.isEmpty {
                    ProgressView("Loading pull requests...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.pullRequests.isEmpty {
                    VStack(spacing: 8) {
                        Text("No pull requests")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Configure repos in Settings")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(appState.filteredPullRequests, selection: $appState.selectedPR) { pr in
                        PRRowView(pr: pr)
                            .tag(pr)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: appState.selectedPR) { _, newPR in
                        guard let pr = newPR, pr.isNew,
                              let idx = appState.pullRequests.firstIndex(where: { $0.id == pr.id }) else { return }
                        appState.pullRequests[idx].isNew = false
                        appState.selectedPR = appState.pullRequests[idx]
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let error = appState.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Toggle("Only my PRs", isOn: $appState.myPRsOnly)
                    Toggle("Needs review", isOn: $appState.needsReviewOnly)
                    Toggle("Hide drafts", isOn: $appState.hideDrafts)
                    Toggle("Hide closed", isOn: $appState.hideClosed)
                } label: {
                    Image(systemName: appState.hasActiveFilters
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("Filter pull requests")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await appState.refreshPRs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(appState.isLoading)
                .help("Refresh pull requests")
            }

            ToolbarItem(placement: .automatic) {
                Circle()
                    .fill(appState.webSocketService.isConnected ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .help(appState.webSocketService.isConnected ? "Live updates connected" : "Live updates disconnected")
            }
        }
    }
```

Two structural changes vs. the previous body:
1. The whole list / loading / empty branch is now wrapped inside `HStack(spacing: 0) { AuthorRailView(); Divider(); Group { ... } }`.
2. `.toolbar { ... }` now hangs off the outer `HStack`, not the inner `Group`. (Same toolbar contents, just moved one level up.)

### Step 3.2: Build the SwiftPM binary

```bash
cd /Users/chang/projects/gh-review/app && swift build
```

Expected: `Build complete!`.

### Step 3.3: Rebuild the `.app` bundle and launch

```bash
cd /Users/chang/projects/gh-review/app && ./scripts/build-app.sh
pkill -f GHReview 2>/dev/null; sleep 1
open build/GHReview.app
```

### Step 3.4: Manual smoke verification

Visually verify in the running app:

1. **Layout:** A thin (~44pt wide) vertical strip sits at the leading edge of the sidebar, separated from the PR list by a 1pt divider.
2. **"All" button:** First circle in the rail shows the `person.3.fill` icon. It has a colored ring (accent color) when no author is selected.
3. **Avatars:** Up to 9 author avatars appear below the "All" button, ordered with the most-recently-active author at the top.
4. **Tooltips:** Hovering each circle shows a tooltip — `"All authors"` on the "All" button, the username on each avatar.
5. **Single-select:** Clicking an avatar filters the PR list to only that author's PRs. The selection ring moves to the tapped avatar; the "All" button loses its ring.
6. **Clear:** Clicking the "All" button restores the full list.
7. **Pinned selection (manual):** Select an author whose PRs are likely to roll off (e.g. an author with one PR), then refresh until that author is no longer in the top-9-by-recency. The avatar should remain visible as the 9th entry in the rail.
8. **Active-filters indicator:** While an author is selected, the toolbar filter icon shows the filled variant (`line.3.horizontal.decrease.circle.fill`).
9. **Composition with other filters:** Selecting an author + enabling "Needs review" should AND the two filters (only that author's PRs that still need review).

If any of these fail, fix and rebuild before committing.

### Step 3.5: Commit

```bash
cd /Users/chang/projects/gh-review
git add app/Sources/PRListView.swift
git commit -m "feat(sidebar): add author avatar rail with single-select filter"
```

### Step 3.6: Push

```bash
git push
```

---

## Notes for the implementer

- **No XCTest:** This project has no test target. Don't add one. Verify by `swift build` + the manual smoke checklist in Step 3.4.
- **Avatar URL stability:** `lastSeenAvatarURL` is populated via a `didSet` hook on `pullRequests`, which fires every time the published array is assigned. This covers the refresh path (full reassignment) and the websocket-driven update paths (in-place mutation also triggers `didSet` for `@Published` arrays). No additional wiring is needed.
- **Toolbar move:** The `.toolbar` modifier is intentionally moved from the inner `Group` to the outer `HStack` in Task 3. SwiftUI's toolbar resolution finds the `NavigationSplitView` ancestor either way, but keeping it on the root of the sidebar view is the cleaner placement.
- **Selection ring style:** `Color.accentColor` is used so the ring respects the user's macOS accent color, matching how native sidebar selection highlights behave.
- **Existing filter persistence:** Per the spec, `selectedAuthor` is in-memory only — matching the existing filter toggles, which also don't persist. Do not add `UserDefaults` plumbing.
