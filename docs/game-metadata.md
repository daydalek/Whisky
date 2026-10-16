# Game metadata integration (initial implementation)

The classic library remains the default. The library toolbar switches to a
portrait bookshelf, remembering the preference. A cover opens details; the play
button launches through the existing library model. Right-click a pinned program
to open its existing runtime settings without navigating into a bottle.

Steam entries also expose runtime settings, but their panel separates Steam
management from Whisky compatibility. Launch options remain in the Windows Steam
client. The advanced compatibility picker explicitly associates an installed
executable's overrides with a Steam App ID; it never copies that executable's
arguments, locale, or environment into Steam and never bypasses `-applaunch`.
Selections use installation-relative paths in `Steam Game Settings/<appid>.plist`.
The existing automatic override selection is preserved until a user explicitly
chooses a target. Shared settings still link to the bottle configuration.

Library rows now observe bottle settings directly for pin changes; these updates
do not wait for a Steam rescan. Rebuilds use current pin state after asynchronous
discovery and discard cancelled or superseded scans. Entries deduplicate by
identity, not title: a local executable with the same title cannot hide a Steam
launch. Source labels distinguish these intentionally separate launch entries.

The bookshelf reserves two title lines and a status/source line for every card,
top-aligns grid cells and increases row/column spacing to keep covers aligned.

## Storage and identity

### Folder games

The library's **Game folders** toolbar action configures scan roots per bottle.
Every visible, non-symlink direct child directory becomes a game, even without an
EXE. There is no recursive executable search. Known Steam installation/library
ancestors and game directories are excluded from this source. Roots are opt-in;
opening/refreshing the library enumerates their direct children in the background.
An unavailable root retains its last known entries; removing a configured root
removes its entries without deleting game files.

On first Run, an EXE picker opens at the game folder. Selection is remembered;
the context menu can choose another executable. Missing selections prompt again,
and cancelling never starts anything. Executable selection and metadata have
independent identities, so changing EXE does not lose the folder's artwork.
Settings also use the selected EXE. `Folder Games.json` stores roots, selections,
last known folder identities and the automatic-metadata switch inside the bottle.
Paths within the bottle are relative; explicitly chosen external paths are absolute.

Automatic metadata matching runs only for the first successful enumeration of a
newly added root, and can be disabled in the directory settings. Subsequent scans
discover folders but do not implicitly query providers. **Sync game details**
rescans configured roots and queries only missing, eligible folder metadata;
successfully matched entries are read locally, never requested again. Initial
pending work is persisted; upgrading existing roots does not rescrape them.
Known packaging/version suffixes
are removed iteratively without deleting arbitrary bracketed subtitles. The
enabled direct providers are searched; a unique exact match across all retained names takes priority; a clearly
leading long-name near-match can also be saved automatically. A source error
allows the remaining providers to be evaluated. Ambiguity requires selection. Other results remain
unlinked and can be searched/confirmed through the existing details sheet.
An initial automatic attempt is consumed before accepting its result; failures
or ambiguities can be retried explicitly with manual sync/search. Existing
metadata is not overwritten. Explicit unlinking creates a manual-only marker so
the next scan cannot undo it. Source-level matching and folder discovery are
covered by fixture tests; broad real-library/UI validation remains outstanding.

**Remove from library** hides an entry persistently using its bottle-relative
metadata identity in `Library Visibility.json`. Scanning does not resurrect it;
game files and pinned-program/runtime settings are untouched. Removing and
re-adding a scan root clears hidden folder entries under that root. The directory
settings can separately hide/show pinned and Steam sources for an empty-library
test without altering actual pins or Steam manifests.

Implementation/privacy disclaimers are not displayed in the library UI. Pending
providers are omitted from the source selector until usable.

Metadata lives in `Game Metadata/` inside each bottle, separate from executable
settings. Program identities use bottle-relative paths, not filenames. Steam
identities use app IDs within that bottle. Moving a bottle preserves associations.
Confirmed covers are cached in `Game Metadata/Covers/` by URL hash. Unlinking
metadata leaves installed files and launch settings untouched; shared cached
images are retained.

Source selections are a global preference stored in UserDefaults under
`libraryMetadataEnabledSources`. They survive sheet dismissal and app restarts,
including an explicitly empty selection. New users default to Bangumi, VNDB,
and Steam. Source identifiers and pending initial matches are
saved locally; no separate search history is stored. Legacy automatic-attempt
timestamps are no longer consulted.

## Provider status

| Source | Current status |
| --- | --- |
| Bangumi | Public game search, candidate confirmation, source snapshot |
| VNDB | Kana API search, multilingual title and developer information |
| Steam | Store search, selected-app details, portrait artwork URL |
| Ymgal | Official OAuth public client, search, selected-game details and source snapshot |
| Hikarinagi | Disabled pending verification of an official direct API; no PotatoVN proxy |

Hikarinagi reports an explicit availability error.
Bangumi and VNDB public requests were smoke-tested using CLANNAD; the Steam live
request timed out in the development environment. Deterministic fixture tests
cover all four enabled source response formats.

The design was informed by PotatoVN's separate parsers and mixed-source
orchestration. This implementation does not bundle PotatoVN code, databases,
translation resources, credentials, or a .NET runtime. Use of service APIs and
artwork remains subject to their respective terms.

### No PotatoVN server dependency

Whisky must not use PotatoVN's sync servers, metadata proxy routes, accounts,
tokens, or application credentials. Hikarinagi's anonymous PotatoVN proxy is
excluded too: anonymous access still depends on PotatoVN infrastructure. A source
may only be enabled after its own official direct API and usage conditions have
been verified. If no independent API is available, leave that source disabled.

## Remaining work toward the agreed full feature

- Verification of an official direct Hikarinagi API, with credential storage
  in Keychain when required.
- Confirmed cross-source identities and field-level merge/provenance. Currently,
  accepting a candidate replaces the source snapshot; no automatic merge occurs.
- Local title/cover overrides and custom cover selection.
- Explicit source-ID lookup and per-source refresh.
- Rich detail-page styling, direct detail-page runtime settings, double-click
  launch, accessibility/UI testing, and large-library performance testing.
- Rate-limit handling, bounded image streaming, thumbnail/downsampling pipeline,
  and cache maintenance. Current requests have a 20-second timeout, images have
  a post-download 15 MiB validation limit, and source errors are independent.

Run core tests with `cd WhiskyKit && swift test --filter GameMetadataTests`.

## YMGal Galgame

YMGal uses the documented public OAuth client for non-commercial use. Search is
available through the 月幕 source checkbox, including existing installations.
The app reuses tokens, refreshes once on authentication rejection, serializes
YMGal requests, caches searches for five minutes and fetches full descriptions
when a candidate is selected. Selected metadata and covers use the existing
local store. HTTP and API-level failures remain visible per source.
Source and terms: https://www.ymgal.games/developer .

## VNDB multilingual matching

VNDB snapshots retain all language titles, romanizations, original title and
aliases. Display prefers Simplified Chinese, Traditional Chinese, then the
original script. A local Chinese folder title is retained when VNDB supplies
another language; the remote identity and names remain stored. Older snapshots
remain readable.

Matching compares all names after case/width/punctuation and Traditional to
Simplified normalization. Exact matches across enabled sources take priority.
A single source failure allows other sources to supply candidates. Long names
(at least eight normalized characters) can match with an edit similarity of
0.92 or greater and a lead of at least 0.12 over the next candidate; these are
initial conservative thresholds. Numeric and edition markers constrain fuzzy
matching. Manual search lists candidates by the same score. Short names and
ambiguous candidates use explicit selection. Packaging cleanup covers recognized
translation-group prefixes and Chinese packaging/version suffixes.
