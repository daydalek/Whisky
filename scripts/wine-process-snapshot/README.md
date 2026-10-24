# WhiskyProcessSnapshot

A small observer for Windows processes in a Wine prefix. It uses the Unicode Toolhelp APIs and writes UTF-8 explicitly with CSV quoting. This avoids CRT locale conversion in Wine's built-in tasklist, including names containing Chinese/Japanese characters or commas.

Build from the repository root:

```sh
make -C scripts/wine-process-snapshot
```

The checked-in output is `WhiskyKit/Sources/WhiskyKit/Wine/Resources/WhiskyProcessSnapshot.exe`, copied into WhiskyKit's resource bundle by SwiftPM. MinGW-w64's `x86_64-w64-mingw32-gcc` is required to rebuild it. The Win32-only entry point imports Kernel32; the observer works independently of application CRT overrides. The PE linker timestamp is fixed for reproducible builds with the same toolchain.

Each CSV row contains image name, Windows PID and compatibility session/memory columns. Lifecycle matching consumes name and PID. Session columns are empty and memory is reported as `0 K`, matching the existing Wine display convention. API or output failures return a nonzero status, which the Swift caller treats as a failed observation.

This helper observes process state. It performs no process termination or game configuration changes.
