# Library state, updates and artwork caching

## Game lifecycle

The library confirms local EXEs, folder games and Steam games through a Unicode Windows process snapshot inside the Bottle. macOS `ps` names serve diagnostics. Local launches show Preparing until Wine accepts the launch command, then Starting until a matching Windows process appears. Each phase has a bounded confirmation deadline. Query failures have a separate UI label and preserve previously observed running state.

Folder-game executable discovery examines the game directory and one subdirectory level. Pinned programs match their selected executable. The most recent library selection resolves shared names within a Bottle. Games with executables outside this scope require selecting their actual game executable.

The bundled 64-bit `WhiskyProcessSnapshot.exe` uses `Process32FirstW`/`Process32NextW` to observe both 32-bit and 64-bit processes and writes explicit UTF-8. It depends on Kernel32 alone. This handles Unicode names that this Wine runtime's built-in tasklist can truncate. Its source and reproducible build recipe live in `scripts/wine-process-snapshot`. Windows process queries capture complete UTF-8 output and stderr separately, preserve the exit code, parse quoted CSV fields, and use a 15-second deadline (three seconds for server probes). Temporary output files avoid waits for inherited pipe handles. Invalid output is reported as a query failure. Idle server probes keep polling from starting a Bottle's wineserver.

A launch wakes the existing scheduler immediately; pending confirmation and a first missing observation use a two-second poll interval. Normal observation uses ten seconds. An exit is confirmed by two consecutive successful observations without the game, or by a stopped wineserver. The end timestamp records the first successful observation of absence. Query failure interrupts consecutive-absence confirmation.

Process observations publish before personal-data writes. A separate persistence task coalesces the latest samples per Bottle, keeping its queue bounded. A locked or failing activity store leaves process observation responsive. Confirmed end dates are retained in memory while persistence retries.

## Recent ordering and automatic updates

Recently played sorts exclusively by `GameActivity.lastSessionEndedAt`, descending. A completed session atomically stores this date and releases its observation lease. Ongoing samples keep that date stable. Launch requests and launch logs stay in their separate records.

Legacy play time, ratings and `lastPlayed` values remain intact. The detail sheet labels legacy timestamps Historical activity time. A legacy record gains a confirmed end date after a newly observed session finishes. Entries with no confirmed end date sort after completed sessions, using stable name ties.

“Update library after a game exits” is enabled by default in Library options and Settings → Library (`libraryRefreshAfterExit`). A confirmed exit updates affected rows and sorting immediately, then refreshes their personal records in the background. The timeline animates to the newest visible completed game. Search filters keep unrelated completions from moving the viewport. Date groups say Last session ended, and every completed card shows its end time. Release dates remain in game details.

Metadata task identity uses sorted catalogue IDs plus the explicit metadata revision, preserving artwork tasks during a reorder. View/sort changes refresh personal records. Overlapping requests retain the union of affected IDs.

## Presentation

Cover appearance uses an approximately 180 ms opacity transition. State changes use 180 ms; filtering and view changes use 220 ms; timeline order changes use 280 ms. Search applies after 150 ms of quiet input. Scroll layouts share an item anchor across presentation modes. Mixed-cover rows anchor to their first entry.

The system Reduce Motion setting disables these transitions, including hover background changes. The layout keeps lazy containers and uses stable entry IDs. Animation runs on changes to order, visibility or state.

## Image work and budgets

Local metadata and cover proportions publish after the first 12 entries and in batches of 48 afterward. All saved local entries load before online matching starts. Decoding, palette extraction, blur generation and derivative maintenance execute in `IconCache`'s actor.

Artwork thumbnails have a maximum edge of 1024 pixels. The processed-artwork memory cache accounts for decoded image and ambient pixel cost with a 160 MiB budget and 250-entry limit. Source images stay in their existing metadata cache.

Persistent images are eagerly decoded on the cache actor before rendering. Processed thumbnails, ambient images and palettes persist in a disposable versioned cache under the user's Caches directory. Local keys include absolute URL, fresh file size, modification timestamp and file number. This supports same-path replacement. Corrupt derivatives regenerate from the original. Atomic writes support interrupted generation.

The disk budget is 256 MiB. Maintenance scans on the first write of a cache instance, then when its estimated byte budget is exceeded; oldest derivatives are removed first. Cache read/write failures preserve source-image loading.

## Verification

Tests cover completion ownership, stable completion dates during new sessions, sleeping-poller wakeup, storage-lock independence, persistence retry, consecutive missing observations, query errors, CSV quoting, output capture and deadlines. `LiveWineSessionTests` accepts explicit Wine binary, isolated prefix and controlled executable environment variables to exercise real process confirmation, exit confirmation and persisted completion. Actual game windows and animation acceptance remain manual checks. Artwork-cache regression tests remain in place.
