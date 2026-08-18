# DaoliYu Library Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the DaoliYu library from an account- and sort-scoped disk snapshot before refreshing from the network.

**Architecture:** A dedicated cache type owns the JSON snapshot and atomic file access. `LibraryTabView` applies a matching snapshot synchronously, preserves it when requests fail, and saves refreshed first-page data after successful loads.

**Tech Stack:** Swift, SwiftUI, Codable, FileManager, async/await, Xcode.

---

### Task 1: Add the Library Cache

**Files:**
- Create: `DynamicIsland/DaoliYu/DaoliYuLibraryCache.swift`

- [x] **Step 1: Define the cache context**

Create a Codable context containing:

```swift
let serverURL: String
let username: String
let songsSort: String
let songsSortOrder: String
let artistsSort: String
let artistsSortOrder: String
let albumsSort: String
let albumsSortOrder: String
```

Conform it to `Equatable` so a snapshot can be rejected when credentials or
sort preferences change.

- [x] **Step 2: Define the snapshot**

Create a Codable snapshot containing its context, playlists, artists, albums,
tracks, and `trackTotal`.

- [x] **Step 3: Implement atomic load and save**

Use:

```swift
FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("atoll_daoliyu_library_cache.json")
```

Decode only when the stored context matches. Encode and write with `.atomic`.

- [x] **Step 4: Parse the cache file**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuLibraryCache.swift
```

Expected: exit code 0.

### Task 2: Apply Cache Before Refresh

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuLibraryView.swift:589-638`

- [x] **Step 1: Build the current cache context**

Read the server URL and username from the existing DaoliYu UserDefaults keys
and combine them with the six AppStorage sort values.

- [x] **Step 2: Load cached content first**

At the start of `loadInitialData`, apply a matching snapshot before setting
`isLoading` and starting network requests:

```swift
if let cached = DaoliYuLibraryCache.load(matching: cacheContext) {
    playlists = cached.playlists
    artists = cached.artists
    albums = cached.albums
    tracks = cached.tracks
    total = cached.trackTotal
    hasMore = tracks.count < total
}
```

- [x] **Step 3: Preserve cached values on request failure**

Replace each list only when its optional request result is non-nil. Do not
assign an empty array merely because a request failed.

- [x] **Step 4: Save refreshed first pages**

After initial refresh and successful sort reloads, save a snapshot using only
the first 50 items from artists, albums, and tracks.

- [x] **Step 5: Parse the library view**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuLibraryView.swift
```

Expected: exit code 0.

### Task 3: Build and Run

**Files:**
- Verify: `DynamicIsland/DaoliYu/DaoliYuLibraryCache.swift`
- Verify: `DynamicIsland/DaoliYu/DaoliYuLibraryView.swift`

- [x] **Step 1: Build Debug**

Run:

```bash
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 2: Restart the app**

Run:

```bash
pkill -x Atoll || true
open ~/Library/Developer/Xcode/DerivedData/DynamicIsland-baxlmerjwafjbrgyrnqxatwnauvd/Build/Products/Debug/Atoll.app
```

Expected: the rebuilt Debug process remains running.
