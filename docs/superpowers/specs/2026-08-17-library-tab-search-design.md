# Library Tab Search Design

## Scope

Update the DaoliYu library search field so it searches only the content type
represented by the active tab.

## Behavior

- Songs query `api/tracks` with the `search` parameter.
- Artists query `api/library/artists` with the `search` parameter.
- Albums query `api/library/albums` with the `search` parameter.
- Playlists filter the complete `api/playlists/mine` response locally by name.
- A query must contain at least two characters before remote search starts.
- Remote requests use the existing 300 ms debounce.
- Switching tabs cancels the previous request and reruns the current query for
  the newly selected tab.
- Clearing the query cancels pending work and restores the normal sorted list.
- The selected library tab persists across view recreation and app launches.
- The first launch defaults to Songs when no saved tab exists.

## State

Keep search results separate from the normal library arrays so searching never
overwrites the loaded or sorted library data. Store independent result arrays
for songs, artists, and albums. Playlists continue using their local computed
filter.

## Rendering

The active tab determines both the result row type and the result collection.
The songs load-more control is hidden while a search query is active.

## Error Handling

Cancelled and failed searches leave the current library data intact. Stale
requests must not replace results after the user changes the query or tab.

## Verification

- Search each tab and confirm only matching row types are shown.
- Switch tabs with a query present and confirm the new tab is searched.
- Clear the query and confirm the original sorted list returns.
- Select a non-Songs tab, restart the app, and confirm that tab is restored.
- Build and launch the Debug app.
