# Library Tab Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the DaoliYu library search field search only the active content tab.

**Architecture:** Add optional server-side search parameters to the existing artist and album requests. Keep independent remote result arrays in `LibraryTabView`, route rendering by the active tab, and retain local filtering for playlists.

**Tech Stack:** Swift, SwiftUI, async/await, URLSession-backed DaoliYu API client, Xcode.

---

### Task 1: Add Library Search Parameters

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuAPIClient.swift:67-79`

- [x] **Step 1: Extend the artist request**

Add `search: String? = nil` to `fetchArtists` and append:

```swift
if let search { query.append(("search", search)) }
```

- [x] **Step 2: Extend the album request**

Add `search: String? = nil` to `fetchAlbums` and append:

```swift
if let search { query.append(("search", search)) }
```

- [x] **Step 3: Parse the API client**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuAPIClient.swift
```

Expected: exit code 0.

### Task 2: Route Search Through the Active Tab

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuLibraryView.swift:55-369`

- [x] **Step 1: Add independent result state**

Replace the track-only result property with:

```swift
@State private var trackSearchResults: [DaoliYuTrack] = []
@State private var artistSearchResults: [DaoliYuArtist] = []
@State private var albumSearchResults: [DaoliYuAlbum] = []
```

- [x] **Step 2: Render results by active section**

When the query has at least two characters, switch on `selectedSection`.
Render local `filteredPlaylists` for playlists and the matching remote result
array for artists, albums, and songs. Do not show song pagination while
searching.

- [x] **Step 3: Restart search when the tab changes**

After assigning `selectedSection`, call:

```swift
handleSearchChange(searchText)
```

This cancels the previous task and searches the new section.

- [x] **Step 4: Search only the selected content type**

Keep the 300 ms debounce and switch on a captured section:

```swift
switch section {
case .songs:
    trackSearchResults = try await apiClient.fetchTracks(
        take: 50,
        search: query
    ).items
case .artists:
    artistSearchResults = try await apiClient.fetchArtists(
        take: 100,
        search: query
    ).items
case .albums:
    albumSearchResults = try await apiClient.fetchAlbums(
        take: 100,
        search: query
    ).items
case .playlists:
    break
}
```

Guard against cancellation and a changed active section before assigning.

- [x] **Step 5: Clear all search state**

Cancel `searchTask`, set `isSearching` to false, and empty all three remote
result arrays when the query is cleared or shorter than two characters.

- [x] **Step 6: Parse the view**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuLibraryView.swift
```

Expected: exit code 0.

### Task 3: Persist the Selected Library Tab

**Files:**
- Modify: `DynamicIsland/DaoliYu/DaoliYuLibraryView.swift:59`

- [x] **Step 1: Store the selected section with AppStorage**

Replace the transient state property with:

```swift
@AppStorage("daoliyu.library.selectedSection")
private var selectedSection: LibrarySection = .songs
```

This preserves the first-launch Songs default while restoring later selections.

- [x] **Step 2: Parse the view**

Run:

```bash
xcrun swiftc -frontend -parse DynamicIsland/DaoliYu/DaoliYuLibraryView.swift
```

Expected: exit code 0.

### Task 4: Build and Run

**Files:**
- Verify: `DynamicIsland/DaoliYu/DaoliYuLibraryView.swift`
- Verify: `DynamicIsland/DaoliYu/DaoliYuAPIClient.swift`

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
