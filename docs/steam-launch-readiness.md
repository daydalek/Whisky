# Steam launch readiness

The game library and `WhiskyCmd launch` share `SteamClientReadiness` and
`SteamGameLaunchMonitor`. A Steam process or an accepted Wine invocation is not
proof that a game has started.

## Sequence

1. Find/start Windows Steam in the selected bottle.
2. Wait for that Steam session's UI initialization and successful login, or
   explicit offline-mode evidence. Cold starts require a new session marker.
3. Send `steam.exe -applaunch <appid>` without copying an executable's arguments.
4. Confirm a matching game process in the same bottle. Only then report success.

After ten seconds of readiness waiting, show this bottle's Windows Steam window
to expose login/connection prompts. Steam process startup allows 150 seconds;
subsequent readiness times out after 180 seconds; game
process confirmation allows 120 seconds. Library cards show the current phase.
Their context menu can cancel a pending Steam launch without stopping the client
or terminating a game. Concurrent library launches share client startup; cancelling
one does not cancel the others.

## Conservative retry

Record a console-log cursor before sending the request. A new GameAction for the
App ID is an acknowledgement, including cloud/statistics synchronization. Such a
request is never resent, even if the game exits between process polls. Without an
acknowledgement, recheck readiness, receipt and process state, and allow at most
one retry. Missing, truncated or rotated logs suppress automatic retries.

## Evidence and limitations

Cold-start process waiting uses host process names plus a new bootstrap session
in the selected bottle, without spawning Wine helpers. Background game tracking
is suspended during shared client startup and does not query `tasklist.exe` when
only unrelated Wine services are visible. This avoids repeatedly keeping Wine's
cold-boot services alive while the registry-import output pipe is being drained.
DLL override imports retain their compatibility settings and log start/completion
and elapsed time to aid diagnosis; a successful registry write alone does not
prove that the caller has finished waiting for the process/output stream.

There is no authenticated Steam IPC readiness API integrated here. The production
probe conservatively uses observed Steam log markers, bounded to 512 KiB per
file. Timestamps are compared only within Steam's log timeline, not against the
macOS clock. Old login/UI markers before the most recent bootstrap session do
not count. Log contents and account identifiers are not emitted by the probe.

The current client's online markers were observed during the Stella of The End
investigation. Offline-mode markers are covered by fixtures but still require a
live offline-mode test; future Steam versions may use different markers. Missing
or unrecognized evidence times out and exposes the Steam window rather than
silently treating a process as ready. This is not a guarantee that every Steam
version's offline mode is recognized.

Process matching uses the existing shallow game-executable discovery. Deeply nested
executables and games that exit before the next poll may not be confirmed; they
are not automatically relaunched after an acknowledgement. No cloud settings,
account credentials, saves or network configuration are changed by this feature.

Run `swift test --filter Steam` in `WhiskyKit` for regression tests. A real cold
start must be tested after the user has closed the game and Steam normally; do
not terminate an active play session to test this path.
