# Metadata configuration bridge contract

All methods use the existing `container` and `entryID` addressing. They are
advertised in `bridge.describe`. Configuration and refresh calls return directly;
unlike `metadata.search` and `metadata.sync`, they do not return job IDs.
Exception: `metadata.configuration.save` and `metadata.refresh` accept optional
`background:true`, returning the standard `{jobID}` response immediately.
Poll `jobs.get` with `jobID`: completed `result` is the ordinary response below,
and failed `error` is the standard structured bridge error. `jobs.cancel` is also
supported. Use this mode for hydration/refresh so network waits do not occupy the
command supervisor.

## Record

```json
{
  "version": 1,
  "defaultSource": "bangumi",
  "categorySources": {"summary": "vndb", "cover": "steam"},
  "bindings": {"bangumi": "123", "vndb": "v17"},
  "snapshots": {"bangumi": {"source": "bangumi", "sourceID": "123", "...": "..."}},
  "manualTitle": "Optional local title",
  "manualSummary": "Optional local summary"
}
```

`snapshots` values use the existing complete `GameMetadata` JSON shape (including
`fetchedAt` in the bridge's existing date encoding). Required record fields are
`version`, `defaultSource`, `categorySources`, `bindings`, and `snapshots`.
Optional manual fields may be omitted or null to remove an override; an empty
string is an intentional override. Category keys are `basic`, `summary`, `cover`,
and `characters`; omit a key to inherit the default (do not send `"inherit"`).
Sources are `bangumi`, `vndb`, `steam`, `ymgal`. IDs are canonical positive decimal
strings with no leading zeros: VNDB prefixes its ID with `v`; other providers use
digits only. Hikarinagi is not an available binding.

Saving a search hit requires adding both its explicit source ID to `bindings`
and its complete search snapshot to `snapshots`. Nothing binds by title.

## Methods

- `metadata.configuration.get`: returns a synthesized default record when absent.
  `hasRecord` distinguishes an existing record from this draft. Defaults come
  from the persistent application preferences. Reading an old single-source
  record migrates it in memory only; the next save persists the versioned record.
- `metadata.configuration.save`: accepts `record` alongside addressing, validates
  and atomically replaces the complete draft. Snapshots not matching their source
  binding are discarded. A saved matching snapshot is retained rather than
  downgraded by re-selecting a search hit for the same ID. This is replacement,
  not patch semantics for configuration fields.
  Optional `hydrate:true` fetches details by confirmed ID for new/changed bindings
  or bindings without a saved snapshot, restricted to `sources:[...]` (or enabled
  preferences if omitted). All fetches finish before one local commit: any failure
  throws and leaves the saved record untouched. Disabled sources are saved locally
  without fetching. Omitting `hydrate` keeps the legacy local-only save behavior.
- `metadata.refresh`: accepts optional `sources: ["bangumi", ...]`. Omission
  refreshes all saved bindings; `[]` refreshes none. Fetches by ID only, never
  searches for other providers. Per-source failure preserves the saved snapshot.
  A binding edited or removed while fetching is not resurrected.

All three return:

```json
{
  "hasRecord": true,
  "record": {},
  "resolved": {
    "metadata": {},
    "provenance": {
      "basic": {"source": "bangumi", "sourceID": "123"},
      "summary": {"source": "vndb", "sourceID": "v17"},
      "title": {"manual": true}
    }
  },
  "capabilities": {
    "bangumi": {"refresh": true, "characters": true},
    "vndb": {"refresh": true, "characters": true},
    "steam": {"refresh": true, "characters": false},
    "ymgal": {"refresh": true, "characters": false},
    "hikarinagi": {"refresh": false, "characters": false}
  },
  "errors": {}
}
```

`errors` maps a provider to a human-readable error string. Missing optional
`resolved.metadata` means the selected basic provider has no matching snapshot.
There is deliberately no fallback to another site's work. Manual text remains
saved in that case, but a complete legacy-compatible display metadata value
requires a basic snapshot. Resolved `GameMetadata` also carries `provenance`;
its top-level source/sourceID identify only the basic category, not every field.
Selected categories without a confirmed binding/snapshot remain blank until bound;
automatic sync copies category preferences but never auto-binds additional providers.
The independent imported/custom cover settings are not changed.

Characters are optional `GameMetadata.characters` entries:
`{id, name, originalName?, role?, imageURL?, pageURL?}`.
Bangumi subject relations and paginated VNDB character API responses populate
them during refresh. Nil means not fetched/unsupported; `[]` means fetched empty.
Character request failure retains the entire previous provider snapshot.

`metadata.apply` remains available with `metadata: GameMetadata`, and optionally
`category`. With no category it selects that source as the per-game default while
retaining other bindings, snapshots, category selections and manual fields.
With a category it selects only that category. Search results are not assumed to
include characters; call refresh after saving confirmed bindings.

## Preferences

`preferences.setMany` accepts `{"values": {"key": value, ...}}` and returns the
same full values as `preferences.read`. Every key/value is validated before any
write. File storage commits once atomically under its existing lock. UserDefaults
updates run synchronously after validation, then synchronize; UserDefaults does
not provide a crash-atomic multi-key transaction.

Defaults:

- `libraryMetadataDefaultSource`: `"bangumi"`
- `libraryMetadataBasicSource`, `libraryMetadataSummarySource`,
  `libraryMetadataCoverSource`, `libraryMetadataCharactersSource`: `"inherit"`
- `libraryMetadataEnabledSources`: `"bangumi,vndb,steam,ymgal,nextmoe"` (empty is valid)
- `libraryOnboardingCompleted`: `false`

Strategy preferences accept the four active providers; only category preferences
accept `"inherit"`. Existing per-game selections remain independent of subsequent
global changes. Search/sync with omitted `sources` use enabled-source preferences;
an explicit empty array means none. Automatic matching prioritizes the default
provider but retains its existing fallback matching behavior.
