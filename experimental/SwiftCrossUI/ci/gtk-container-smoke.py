#!/usr/bin/env python3
"""Verify container navigation and actual persisted edits in an isolated prefix."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import plistlib

import pyatspi

spec = importlib.util.spec_from_file_location("gtk_smoke", Path(__file__).with_name("gtk-smoke.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ContainerSmoke(module.GtkSmoke):
    def text_entries(self):
        return [node for node, _, role, _ in self.tree(self.main_window()) if role == "text"]

    def run(self):
        self.wait(lambda: self.label("Alpha") and self.label("2 个游戏"), "initial library")
        self.press(self.button("◇  Fixture Container    2"))
        self.wait(lambda: self.find("push button", "已安装的程序"), "container overview")
        self.snapshot("container-overview")
        self.press(self.button("已安装的程序"))
        self.wait(lambda: self.find("push button", "game"), "program scan")
        self.snapshot("programs")
        self.press(self.button("固定"))
        self.wait(lambda: self.find("push button", "取消固定"), "saved pin")
        metadata_path = self.bottle / "Metadata.plist"
        metadata = plistlib.loads(metadata_path.read_bytes())
        assert len(metadata["info"]["pins"]) == 1
        assert metadata["info"]["pins"][0]["name"] == "game"
        assert metadata["future"] == {"retained": "opaque"}
        self.record("real installed program scan and pin persistence")

        self.press(self.button("隐藏"))
        self.wait(lambda: self.find("push button", "game") is None, "blocked executable")
        hidden = self.wait(lambda: self.find("toggle button", "显示隐藏程序"), "hidden program toggle")
        assert hidden.queryAction().doAction(0)
        self.wait(lambda: self.find("push button", "恢复显示"), "blocked program restoration control")
        self.press(self.button("恢复显示"))
        self.wait(lambda: self.find("push button", "隐藏"), "restored executable")
        assert plistlib.loads(metadata_path.read_bytes())["info"]["blocklist"] == []
        self.record("program hide and restore persist through the original blocklist")

        self.press(self.button("设置"))
        self.wait(lambda: self.find("push button", "⌄  程序配置"), "program settings")
        entries = self.wait(lambda: self.text_entries() if len(self.text_entries()) >= 3 else None, "arguments and variable entries")
        assert entries[0].queryEditableText().setTextContents("--crossui 中文")
        self.press(self.button("保存"))
        self.wait(lambda: self.label("已保存：运行参数"), "argument write")
        self.snapshot("program-settings")
        identity = hashlib.sha256(b"/drive_c/Program Files/Game/game.exe").hexdigest()[:8]
        program_path = self.bottle / "Program Settings" / f"game-{identity}.plist"
        saved = plistlib.loads(program_path.read_bytes())
        assert saved["arguments"] == "--crossui 中文"
        assert saved["environment"]["CUSTOM"] == "retained" and saved["futureProgram"] == 42
        self.record("program settings use the native identity and retain legacy fields")

        entries = self.text_entries()
        assert entries[-2].queryEditableText().setTextContents("CROSSUI_VAR")
        assert entries[-1].queryEditableText().setTextContents("literal $HOME")
        self.press(self.button("保存变量"))
        self.wait(lambda: self.label("CROSSUI_VAR"), "environment variable write")
        assert plistlib.loads(program_path.read_bytes())["environment"]["CROSSUI_VAR"] == "literal $HOME"
        self.record("environment editor persists literal values")

        self.press(self.button("‹ 返回"))
        self.wait(lambda: self.find("push button", "game"), "back to programs")
        self.press(self.button("‹ 返回"))
        self.wait(lambda: self.find("push button", "容器配置"), "back to overview")
        self.wait(lambda: self.find("push button", "game"), "pinned program overview")
        self.press(self.button("运行中的进程"))
        self.wait(lambda: self.label("此平台提供容器与程序配置；Wine 进程管理在 macOS 运行时中使用。"), "Linux process capability")
        assert not self.button("刷新进程").getState().contains(pyatspi.STATE_SENSITIVE)
        self.snapshot("process-capability")
        self.press(self.button("‹ 返回"))
        self.wait(lambda: self.find("push button", "容器配置"), "process back navigation")
        self.record("pinned overview reload and Linux runtime capability")
        before_configuration = metadata_path.read_bytes()
        self.press(self.button("容器配置"))
        self.wait(lambda: self.find("push button", "⌄  Wine"), "container configuration")
        self.snapshot("configuration")
        assert metadata_path.read_bytes() == before_configuration, "Opening configuration changed stored settings"
        assert self.label("已保存：Windows 版本") is None, "Picker initialization invoked the save action"
        self.press(self.button("›  图形"))
        self.wait(lambda: self.find("combo box", "DXVK"), "legacy DXVK selection")
        self.press(self.button("⌄  图形"))
        switches = [node for node, _, role, _ in self.tree(self.main_window()) if role == "check box" and node.getState().contains(pyatspi.STATE_SENSITIVE)]
        assert switches, "Wine configuration switch missing"
        assert switches[0].queryAction().doAction(0)
        self.wait(lambda: self.label("已保存：AVX 支持"), "Wine configuration persistence")
        assert plistlib.loads(metadata_path.read_bytes())["wineConfig"]["avxEnabled"] is True
        assert plistlib.loads(metadata_path.read_bytes())["future"] == {"retained": "opaque"}
        self.record("container configuration writes the actual plist and retains unknown fields")

        self.press(self.button("‹ 返回"))
        self.wait(lambda: self.find("push button", "容器配置"), "configuration back navigation")
        self.press(self.button("容器配置"))
        self.wait(lambda: self.find("label", "AVX 支持"), "configuration reload")
        checkboxes = [node for node, _, role, _ in self.tree(self.main_window()) if role == "check box"]
        assert checkboxes and checkboxes[0].getState().contains(pyatspi.STATE_CHECKED)
        self.press(self.button("›  显示"))
        entries = self.wait(lambda: self.text_entries() if len(self.text_entries()) == 2 else None, "custom resolution fields")
        before_invalid = metadata_path.read_bytes()
        assert entries[0].queryEditableText().setTextContents("invalid")
        self.press(self.button("保存"))
        self.wait(lambda: self.label("保存失败：设置值超出允许范围：自定义宽度"), "invalid numeric input feedback")
        assert metadata_path.read_bytes() == before_invalid
        entries = self.text_entries()
        assert entries[0].queryEditableText().setTextContents("2560")
        self.press(self.button("保存"))
        self.wait(lambda: self.label("已保存：自定义宽度"), "valid resolution write")
        assert plistlib.loads(metadata_path.read_bytes())["displayConfig"]["customWidth"] == 2560
        self.record("numeric validation reports errors and persists valid configuration")
        self.snapshot("completed")
        after = self.file_hashes()
        allowed = {"bottle/Metadata.plist", "bottle/Metadata.plist.lock", f"bottle/Program Settings/game-{identity}.plist", f"bottle/Program Settings/game-{identity}.plist.lock"}
        changed = {key for key in set(self.before) | set(after) if self.before.get(key) != after.get(key)}
        assert changed <= allowed, f"Unexpected file writes: {changed - allowed}"
        self.record("navigation reload and isolated write scope")


parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()
smoke = ContainerSmoke(args.binary, args.output, container_pages=True)
try:
    smoke.run()
except Exception as error:
    smoke.finish(error)
    raise
else:
    if not smoke.finish():
        raise SystemExit(1)
