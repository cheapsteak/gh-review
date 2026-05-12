# Author Rail Quick Filter — Design

## Goal

Add a thin vertical "author rail" to the left of the PR list in the sidebar, letting the user single-select an author to filter the list to just that person's PRs. An "All" affordance at the top clears the filter.

## User-visible behavior

- A ~44pt-wide vertical rail at the leading edge of the sidebar, sitting flush with the PR list.
- Top of the rail: a circular **All** button using SF Symbol `person.3.fill`, selected by default.
- Below: up to **9** circular author avatars, one per unique author of currently-loaded PRs, ordered by most-recent PR activity (descending by `updatedAt`, falling back to `createdAt`).
- Tapping an avatar single-selects that author; the PR list filters to only their PRs (combined with existing filters via AND).
- Tapping **All** clears the author filter.
- Selection persists in memory for the app session. It is **not** written to disk (matches the existing pattern for `needsReviewOnly`, `hideDrafts`, `hideClosed`, `myPRsOnly` — none of which persist).
- **Stale selection:** If the selected author no longer appears in `pullRequests` (e.g. their PRs got filtered out by other toggles or merged off-list), the selection is preserved in state. The rail visually pins the selected author into the 9 slots regardless of their rank (see "Pinned selection" below).
- Hovering an avatar shows the author's username as a tooltip.
- Avatar load failure falls back to SF Symbol `person.circle.fill`, matching `PRRowView`.

## Layout & visual treatment

- Rail width: 44pt fixed.
- Avatar size: 28pt diameter, clipped to `Circle`.
- Vertical spacing between items: 6pt.
- Top padding: 8pt; bottom padding: 8pt.
- Selection ring: 2pt stroke in `Color.accentColor` around the selected circle. Unselected items have no ring.
- Hover: subtle background highlight (e.g. `Color.secondary.opacity(0.1)` behind the circle on hover).
- Rail itself sits inside a `ScrollView(.vertical, showsIndicators: false)` so the design tolerates more than 9 items gracefully (though we cap at 9 — the scroll is defensive).
- Background: matches the sidebar material (no extra fill needed).
- Rail and list are separated by a 1pt `Divider` for visual structure.

## Pinned selection (top-9 with pinned author)

When computing what to show in the 9 author slots:

1. Compute `authorsByRecency` — all unique authors in `pullRequests`, sorted descending by their most recent PR's `updatedAt` (falling back to `createdAt`).
2. If `selectedAuthor == nil`, show `authorsByRecency.prefix(9)`.
3. If `selectedAuthor != nil`:
   - If the selected author is within `authorsByRecency.prefix(9)`, show `authorsByRecency.prefix(9)` as-is.
   - Otherwise, show `authorsByRecency.prefix(8)` + the selected author appended at the end. The slot count stays at 9.
   - If the selected author is not in `authorsByRecency` at all (no current PRs by that author), still surface them as the 9th item using whatever avatar URL was last seen for them.

This keeps the rail size predictable and the active selection always visible.

## Avatar URL caching

`pullRequests` already exposes `avatarURL` per PR. To support the "stale selection" case where the selected author has no PRs in the current set, we maintain a small `[String: String]` map of `author -> last-seen avatarURL`, updated whenever `pullRequests` changes. This lives on `AppState`.

## Filter integration

- New `@Published var selectedAuthor: String? = nil` on `AppState`.
- `filteredPullRequests` gains a clause:
  ```swift
  if let selectedAuthor {
      result = result.filter { $0.author == selectedAuthor }
  }
  ```
  Applied alongside the existing filters (order does not matter — composition is AND).
- `hasActiveFilters` is updated to include `selectedAuthor != nil`.

## Architecture

### `AppState` (in `app/Sources/GHReviewApp.swift`)

Add:
- `@Published var selectedAuthor: String? = nil`
- `private var lastSeenAvatarURL: [String: String] = [:]` — populated whenever `pullRequests` is updated (in the existing refresh + websocket paths).
- A computed `var authorsByRecency: [AuthorRailEntry]` that returns up to 9 entries built using the rules above. `AuthorRailEntry` is a small value type: `struct AuthorRailEntry: Hashable { let username: String; let avatarURL: String }`.
- Update `hasActiveFilters` and `filteredPullRequests` as described.

### `AuthorRailView` (new, in `app/Sources/PRListView.swift`)

A new `View` rendering the rail. It reads `appState.authorsByRecency`, `appState.selectedAuthor`, and writes to `appState.selectedAuthor` on tap. Internally:
- Top "All" button (own subview `AllAuthorsButton`) — `person.3.fill` SF symbol in a 28pt circle, selection ring when `selectedAuthor == nil`.
- `ForEach` over `appState.authorsByRecency` rendering `AuthorAvatarButton` instances.
- Each `AuthorAvatarButton` shows the avatar via `AsyncImage`, clipped to a circle, with selection ring when `appState.selectedAuthor == entry.username`, and a `.help(entry.username)` tooltip.

### `PRListView` body change (in `app/Sources/PRListView.swift`)

Wrap the existing list body in an `HStack(spacing: 0)`:

```swift
HStack(spacing: 0) {
    AuthorRailView()
        .frame(width: 44)
    Divider()
    existingListBody
}
```

The `.toolbar` modifier stays attached to the outer `HStack` (which is the sidebar's root view), so toolbar items continue to render correctly.

## Edge cases

- **Empty PR list:** Rail shows only the "All" button. No author slots.
- **<9 unique authors:** Rail shows however many there are. No empty slots.
- **Bot authors:** Treated like any other author — they appear in the rail if their PRs are loaded. (Filtering bots is the user's existing "hidden authors" responsibility.)
- **Avatar URL changes:** If a PR's `avatarURL` updates for an author, `lastSeenAvatarURL` is overwritten. The rail picks up the new URL on next render.
- **Author with mixed-case usernames:** Match on exact `pr.author` string (GitHub usernames are case-insensitive, but the API returns canonical casing; same string for the same person).

## Out of scope (explicit non-goals)

- Multi-select.
- Exclude-mode (shift-click to hide).
- Persistence of `selectedAuthor` across app restarts.
- Configurable rail size / position.
- Search field inside the rail.
- Showing PR count badges on avatars.
- Surfacing >9 authors via overflow menus.

## Files touched

- `app/Sources/GHReviewApp.swift` — extend `AppState` with `selectedAuthor`, `lastSeenAvatarURL`, `authorsByRecency`, and update `hasActiveFilters` + `filteredPullRequests`.
- `app/Sources/PRListView.swift` — wrap the body in `HStack { AuthorRailView; Divider; List }`; add `AuthorRailView`, `AllAuthorsButton`, and `AuthorAvatarButton` subviews.
