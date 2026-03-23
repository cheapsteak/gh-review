---
name: update-project-docs
description: Regenerate GH Review project documentation (architecture.md, file-map.md) from current source code. Use when significant structural changes have been made — new files, renamed modules, new API methods, changed architecture. Invoke with "/update-project-docs".
---

# Update Project Docs

Regenerates the reference documentation in `.claude/skills/gh-review-project/references/` by scanning the current source tree.

## When to Run

- After adding new source files
- After adding new GitHub API methods
- After changing the relay server routes or Durable Object behavior
- After significant UI restructuring (new views, changed column layout)
- After changing the build/bundle process

## What to Update

### 1. File Map (`references/file-map.md`)

Scan `app/Sources/` and `relay/src/` for all source files. For each file, write a one-line description of what it does. Read each file briefly to determine its purpose — don't guess from the filename alone.

Check for:
- New files not yet documented
- Deleted files still listed
- Files whose purpose has significantly changed

### 2. Architecture (`references/architecture.md`)

Review these sections and update if they've drifted from the code:
- **Relay routes** — compare against route handling in `relay/src/index.ts`
- **Webhook envelope format** — compare against the envelope construction in `relay/src/index.ts`
- **GitHub API methods** — compare against methods in `app/Sources/GitHubAPI.swift`
- **Component hierarchy** — compare against view files in `app/Sources/`
- **Data flow** — compare against `AppState` in `app/Sources/GHReviewApp.swift`
- **Filtering logic** — compare against `filteredPullRequests` in `AppState`
- **Notification flow** — compare against `sendNotification` in `AppState`

### 3. SKILL.md

Only update if conventions have changed (e.g., new dependencies, changed build process, new state management patterns). The SKILL.md should be stable — it describes patterns, not specific files.

## Process

1. Read `app/Package.swift` to understand current dependencies
2. List all source files under `app/Sources/` and `relay/src/`
3. For new/changed files, read them briefly to understand purpose
4. Update `references/file-map.md`
5. Read key source files to verify architecture.md accuracy
6. Update `references/architecture.md` if anything changed
7. Commit with message: `docs: update project references`

## Do NOT

- Rewrite SKILL.md unless conventions actually changed
- Add speculative documentation for features not yet built
- Remove entries for files that exist (only remove for deleted files)
- Change the document structure/formatting — keep it consistent
