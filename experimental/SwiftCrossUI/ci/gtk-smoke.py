#!/usr/bin/env python3
"""Exercise the real Gtk window through AT-SPI and X11 using isolated data."""

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time

import pyatspi


class GtkSmoke:
    def __init__(self, binary, output, container_pages=False):
        self.binary = Path(binary).resolve()
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=self.output))
        self.bottle = self.fixture / "bottle"
        for name in ["Alpha", "Beta", "Hidden", "Excluded"]:
            (self.bottle / "Games" / name).mkdir(parents=True)
        (self.bottle / "Folder Games.json").write_text(json.dumps({
            "roots": ["Games"], "excludedFolders": ["Games/Excluded"],
            "automaticMetadata": False,
        }))
        (self.bottle / "Library Visibility.json").write_text(json.dumps({
            "hiddenIdentities": ["program:Games/Hidden"], "includePinnedAndSteam": True,
        }))
        self.selected = self.fixture / "Selected"
        suffix = self.fixture.name.rsplit("-", 1)[-1][:6]
        self.selected_names = [f"Delta {suffix}", f"Gamma {suffix}"]
        for name in self.selected_names:
            (self.selected / name).mkdir(parents=True)
        if container_pages:
            metadata = {"info": {"name": "Fixture Container", "pins": []}, "future": {"retained": "opaque"},
                        "dxvkConfig": {"dxvk": True}}
            (self.bottle / "Metadata.plist").write_bytes(plistlib.dumps(metadata))
            executable = self.bottle / "drive_c" / "Program Files" / "Game" / "game.exe"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture executable")
            settings = self.bottle / "Program Settings" / "game.exe.plist"
            settings.parent.mkdir()
            settings.write_bytes(plistlib.dumps({"locale": "", "arguments": "--legacy", "environment": {"CUSTOM": "retained"}, "futureProgram": 42}))
        self.before = self.file_hashes()
        self.steps = []
        self.log = (self.output / "application.log").open("w")
        self.app = subprocess.Popen(
            [str(self.binary), "--bottle", str(self.bottle)],
            stdout=self.log, stderr=subprocess.STDOUT,
        )

    def file_hashes(self):
        return {
            str(file.relative_to(self.fixture)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in sorted(self.fixture.rglob("*")) if file.is_file()
        }

    def tree(self, root=None):
        stack = [(root or pyatspi.Registry.getDesktop(0), 0)]
        result = []
        while stack and len(result) < 1000:
            node, depth = stack.pop()
            if node is None or depth > 96:
                continue
            try:
                node.clear_cache_single()
                role, name = node.getRoleName(), node.name
                result.append((node, depth, role, name))
                stack.extend((child, depth + 1) for child in reversed(list(node)) if child is not None)
            except Exception:
                continue
        return result

    def find(self, role, name=None, root=None):
        for node, _, actual_role, actual_name in self.tree(root):
            if actual_role == role and (name is None or actual_name == name):
                return node
        return None

    def wait(self, predicate, description, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.app.poll() is not None:
                raise AssertionError(f"Application exited during {description}: {self.app.returncode}")
            result = predicate()
            if result:
                return result
            time.sleep(0.1)
        raise AssertionError(f"Timed out waiting for {description}")

    def main_window(self):
        return self.wait(lambda: self.find("frame", "Whisky · SwiftCrossUI"), "main window")

    def label(self, name):
        return self.find("label", name, self.main_window())

    def button(self, name, root=None):
        return self.wait(
            lambda: self.find("push button", name, root or self.main_window()),
            f"button {name}",
        )

    def press(self, button):
        assert button.getState().contains(pyatspi.STATE_SENSITIVE), f"Button disabled: {button.name}"
        assert button.queryAction().doAction(0), f"Button action failed: {button.name}"

    def command(self, *args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=10)

    def snapshot(self, name):
        data = []
        for node, depth, role, title in self.tree():
            try:
                data.append({
                    "depth": depth, "role": role, "name": title,
                    "sensitive": node.getState().contains(pyatspi.STATE_SENSITIVE),
                })
            except Exception:
                continue
        (self.output / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2))
        # Let Gtk publish a frame after the synchronous accessibility queries.
        time.sleep(0.2)
        self.command("import", "-window", "root", str(self.output / f"{name}.png"))

    def record(self, step):
        self.steps.append(step)
        print(f"PASS {step}", flush=True)

    def run(self):
        self.wait(lambda: self.label("Alpha") and self.label("Beta") and self.label("2 个游戏"), "initial catalogue")
        assert self.label("Hidden") is None and self.label("Excluded") is None
        self.snapshot("loaded")
        self.record("configured folder discovery and visibility")

        search = self.find("text", root=self.main_window())
        assert search is not None
        assert search.queryEditableText().setTextContents("bEtA")
        self.wait(lambda: self.label("1 个游戏") and self.label("Beta") and self.label("Alpha") is None, "search filter")
        self.snapshot("filtered")
        self.record("case-insensitive search updates the real list")

        self.press(self.button("Beta"))
        self.wait(lambda: self.find("label", "游戏详情"), "game details")
        launch = self.wait(lambda: self.find("push button", "▶ 游玩"), "details launch capability")
        assert not launch.getState().contains(pyatspi.STATE_SENSITIVE)
        self.snapshot("details")
        self.press(self.wait(lambda: self.find("push button", "完成"), "details close"))
        self.wait(lambda: self.find("label", "游戏详情") is None, "details dismissal")
        self.record("game detail opens from the real row and respects runtime capabilities")

        search = self.find("text", root=self.main_window())
        assert search.queryEditableText().setTextContents("")
        self.wait(lambda: self.label("2 个游戏") and self.label("Alpha"), "cleared search")
        for title in ["书架", "经典卡片", "时间线"]:
            self.press(self.button(title))
            self.wait(lambda: self.label("Alpha") and self.label("Beta"), f"catalogue after {title}")
            self.snapshot({"书架": "shelf", "经典卡片": "cards", "时间线": "timeline"}[title])
        self.record("all three library layouts retain the real catalogue")

        self.press(self.button("打开游戏目录"))
        dialog_name = "选择包含游戏文件夹的目录"
        dialog = self.wait(lambda: self.find("dialog", dialog_name), "directory chooser")
        self.snapshot("directory-dialog")
        windows = self.command("xdotool", "search", "--onlyvisible", "--name", f"^{dialog_name}$").stdout.split()
        assert windows, "Directory dialog X11 window missing"
        self.command("xdotool", "windowfocus", "--sync", windows[-1])
        self.command("xdotool", "key", "--clearmodifiers", "ctrl+l")
        location = self.wait(lambda: self.find("text", root=dialog), "directory location entry")
        assert location.queryEditableText().setTextContents(str(self.selected))
        self.snapshot("directory-location")
        self.command("xdotool", "key", "--clearmodifiers", "Return")
        self.wait(
            lambda: all(self.label(name) for name in self.selected_names) and self.label("2 个游戏"),
            "selected directory catalogue",
        )
        self.wait(lambda: self.find("dialog", dialog_name) is None, "directory acceptance")
        assert self.label("Alpha") is None and self.label("Beta") is None
        self.snapshot("directory-selected")
        self.record("directory chooser accepts a folder and changes the selected catalogue")

        self.press(self.button("打开游戏目录"))
        dialog = self.wait(lambda: self.find("dialog", dialog_name), "chooser cancellation")
        self.press(self.button("Cancel", dialog))
        self.wait(lambda: self.find("dialog", dialog_name) is None, "cancelled chooser")
        assert all(self.label(name) is not None for name in self.selected_names)
        assert self.file_hashes() == self.before, "Browsing changed fixture files"
        self.snapshot("completed")
        self.record("dialog cancellation and configuration preservation")

    def finish(self, error=None):
        if error is not None:
            self.snapshot("failure")
        before_cleanup = self.app.poll()
        if before_cleanup is None:
            self.app.terminate()
            self.app.wait(timeout=10)
        elif error is None:
            error = AssertionError(f"Application exited before cleanup: {before_cleanup}")
        self.log.close()
        native_errors = [
            line for line in (self.output / "application.log").read_text().splitlines()
            if "CRITICAL" in line or "Fatal error:" in line
        ]
        if native_errors and error is None:
            error = AssertionError("Native runtime errors: " + "; ".join(native_errors))
        result = {
            "status": "passed" if error is None else "failed",
            "steps": self.steps, "error": str(error) if error else None,
            "binary_sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "fixture": str(self.fixture), "fixture_unchanged": self.file_hashes() == self.before,
            "selected_directory": str(self.selected), "selected_names": self.selected_names,
            "application_running_before_cleanup": before_cleanup is None,
            "application_exit_after_cleanup": self.app.returncode,
            "native_errors": native_errors,
        }
        (self.output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        return error is None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    smoke = GtkSmoke(args.binary, args.output)
    try:
        smoke.run()
    except Exception as error:
        smoke.finish(error)
        raise
    else:
        if not smoke.finish():
            raise SystemExit(1)


if __name__ == "__main__":
    main()
