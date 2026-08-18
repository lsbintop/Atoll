# DaoliYu Library Cache Design

## Goal

Show the DaoliYu library immediately from disk when the view opens, then refresh
the cached lists in the background.

## Cached Data

- Ordered user playlists.
- The first 50 artists for the saved artist sort.
- The first 50 albums for the saved album sort.
- The first 50 tracks for the saved song sort.
- Track total count for pagination.

## Cache Identity

The snapshot records the configured server URL and username. It is accepted only
when both values still match the active credentials. This prevents content from
another server or account from appearing.

The snapshot also records the song, artist, and album sort fields and directions.
It is accepted only when all saved sort values match the current preferences.

## Data Flow

1. `LibraryTabView` loads and applies a valid snapshot before setting the network
   loading state.
2. It starts the existing favorites and library requests in the background.
3. Each successful response replaces its corresponding cached list.
4. Failed responses leave the cached list intact.
5. The resulting first-page snapshot is written atomically after refresh.
6. Successful sort reloads update the relevant list and replace the snapshot.

## Storage

`DaoliYuLibraryCache` owns JSON encoding and file access. It stores one snapshot
under the user's caches directory. Invalid or corrupt files are ignored.

Only the first 50 items of each paginated section are stored to keep startup
decoding and disk usage bounded. Search results and detail-page data are not
cached.

## Verification

- Populate the library, close and reopen it, and confirm content appears before
  background requests finish.
- Disable the server after a successful load and confirm cached content remains.
- Change a sort option and confirm the new order is cached.
- Change server or username and confirm the previous snapshot is ignored.
- Build and launch the Debug app.
