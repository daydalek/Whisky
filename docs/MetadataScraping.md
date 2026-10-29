# Metadata and character scraping

The GPUI library persists character lists with each game's metadata. A saved empty
list records a completed lookup. Opening an entry with saved characters reads that
snapshot; opening Game Info can fetch a missing list for VNDB or Bangumi when the
character setting is enabled. Manual refresh uses a retained bridge job, keeping
network work outside the short bridge request deadline.

## Request bounds

- Search, details and character operations share a per-source serialized gate with
  a 250 ms interval after each operation. A VNDB character lookup uses one novel
  request and, when it returns no voiced cast, one character fallback request.
- Character results, including empty lists, are cached for 10 minutes in a bounded
  per-source memory cache. Concurrent lookups share the completed result. Manual
  refresh within that window uses the same cached result.
- A timed-out character operation retries once after one second; each character
  HTTP request has a 45 second timeout. Failed lookups have a 30 second per-game
  cooldown. HTTP 429/503 honor Retry-After and share cooldown with search/details.
- Portrait URLs are deduplicated per cast. Existing files are reused. Downloads
  across apply/sync jobs in a bridge service run serially with a 250 ms interval;
  remote 429/503 responses trigger a cooldown. Downloads use the existing HTTPS,
  20 second timeout and 15 MiB response validation rules.

Initial synchronization may fetch one cast and its uncached portraits for each
new match. Its total transfer scales with cast sizes and image sizes. Disabling
character scraping skips that initial work; saved metadata and artwork remain
available locally. Independent application processes have independent gates.

## NextMoe routes in GPUI

The GPUI **游戏资料与封面…** search includes **NextMoe**. Applying a NextMoe
work attaches its title, cover, developer, introduction and walkthrough index.
Alternatively, **攻略路线 → 查找 NextMoe 游戏资料…** searches only NextMoe;
select **获取路线** to attach its walkthrough index without replacing existing
metadata or artwork. The selected work can be changed from the route card.
The **攻略路线** card lists guide authors, languages, versions and ending/save
counts. **打开路线图** opens an opaque, dedicated graph canvas. Entries, saves,
choice groups and endings have distinct colors and connecting curves. Shared
save nodes connect the routes that resume from them. Continuous choice runs
start collapsed; clicking their route node reveals individual steps. Toolbar
controls switch between a compact overview and all steps, switch original/translated
text, fit the graph, restore readable size, and zoom. Wheel or two-finger scrolling
pans; Shift-wheel pans horizontally. Pinch or Command/Control-wheel zooms around
the pointer, and dragging empty canvas pans. The large canvas also closes with Escape. Built-in route hints, partial
import coverage and original author links remain in the guide selection view.


Public catalog reads use `https://api.nextmoe.dev/v2/catalog` with anonymous
access. Work searches use `works?q=...&include=titles,intros,companies`; guide
indexes follow every `next_cursor` from `walkthroughs?work_id=...`. Requests
include R18 works (`nsfw=true`) and keep catalog presentation at `content_limit=sfw`.
The shared transport serializes requests with a 2.1-second interval and honors
429/503 `Retry-After` (60 seconds when absent). Search/detail caches reuse the
existing provider gates. The anonymous API quota also has a daily allowance;
quota failures remain visible and allow a later retry.

Charts download only when a guide is selected. Downloads run as retained
`metadata.apply` jobs with a `walkthroughID` field inside the metadata snapshot.
The bridge checks the independently selected NextMoe work (or the source work for
older snapshots), guide membership and response work ID,
then merges the chart into the latest matching snapshot. Full graph JSON survives
storage and Rust DTO round trips, including future step kinds. Cached guides remain
available in offline mode; online fetches use the existing network policy.

API contract: [NextMoe v2](https://developer.nextmoe.dev/docs/v2),
[walkthrough index](https://developer.nextmoe.dev/docs/v2/listCatalogWalkthroughs),
[walkthrough graph](https://developer.nextmoe.dev/docs/v2/getCatalogWalkthrough).
Data attribution: **NextMoe · 鲲 Galgame 论坛** and each guide's original author/page.
