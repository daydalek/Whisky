#!/usr/bin/env bash
set -euo pipefail

prototype_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
portability_build_dir="${WHISKY_CROSSUI_BUILD_DIR:-$prototype_dir/../../build/portability/linux-crossui/swiftpm}"
gui_output="${WHISKY_GUI_OUTPUT_DIR:-$prototype_dir/../../build/portability/gui-linux/run-$(date -u +%Y%m%dT%H%M%SZ)}"
case "${WHISKY_GUI_SCENARIO:-library}" in
    library) smoke_script="gtk-smoke.py" ;;
    containers) smoke_script="gtk-container-smoke.py" ;;
    *) echo "Unknown GUI scenario: $WHISKY_GUI_SCENARIO" >&2; exit 2 ;;
esac

exec xvfb-run -a -s "-screen 0 1280x900x24 -nolisten tcp" \
    dbus-run-session -- env GTK_A11Y=atspi GDK_BACKEND=x11 GSK_RENDERER=cairo \
    python3 "$prototype_dir/ci/$smoke_script" \
    --binary "$portability_build_dir/debug/WhiskyCrossUI" --output "$gui_output"
