#!/usr/bin/env python3
"""Self-test iPaste logic that does not need AppKit.

Mirrors CopyEffectGate, CopyChordState, ScreenGeometry, and the updater's
version compare. Also static-checks the signing, overlay, and install-script
constraints from the MVP.
"""
from __future__ import annotations

import math
import plistlib
import re
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MARKER = "io.github.bianyanhui.iPaste.selfWrite"
ARM_TIMEOUT = 1.2


def normalized_version(raw: str) -> str:
    s = raw.strip()
    if s.lower().startswith("v"):
        s = s[1:]
    return s


def numeric_parts(version: str) -> list[int]:
    parts = []
    for part in normalized_version(version).split("."):
        i = 0
        while i < len(part) and part[i].isdigit():
            i += 1
        parts.append(int(part[:i] or "0"))
    return parts


def is_version_newer(lhs: str, rhs: str) -> bool:
    a, b = numeric_parts(lhs), numeric_parts(rhs)
    n = max(len(a), len(b))
    for i in range(n):
        x = a[i] if i < len(a) else 0
        y = b[i] if i < len(b) else 0
        if x != y:
            return x > y
    return False


def should_show(change: int, baseline: int, types: list[str], last_self: int) -> bool:
    if change <= baseline:
        return False
    if change <= last_self:
        return False
    if MARKER in types:
        return False
    return True


class Chord:
    def __init__(self) -> None:
        self.baseline: int | None = None
        self.armed_at: float | None = None

    def note_key_down(self, is_plain: bool, is_repeat: bool, change: int, now: float) -> None:
        if not is_plain or is_repeat:
            return
        self.baseline = change
        self.armed_at = now

    def note_key_up(self, is_c: bool, now: float) -> int | None:
        if not is_c or self.baseline is None or self.armed_at is None:
            return None
        baseline = self.baseline
        armed_at = self.armed_at
        self.baseline = None
        self.armed_at = None
        if now - armed_at > ARM_TIMEOUT:
            return None
        return baseline


def is_plain_command_c(key_code: int, command: bool, shift: bool, control: bool, option: bool, is_repeat: bool) -> bool:
    if key_code != 8 or is_repeat:
        return False
    if not command:
        return False
    if shift or control or option:
        return False
    return True


def round_half_away(value: float) -> float:
    return math.copysign(math.floor(abs(value) + 0.5), value)


def snap(value: float, scale: float) -> float:
    return round_half_away(value * scale) / scale


def panel_frame(mouse, size, screen, visible, scale, lift=48.0):
    w, h = size
    x = mouse[0] - w / 2
    y = mouse[1] + lift - h / 2
    bounds = visible if visible[2] > 0 and visible[3] > 0 else screen
    max_x = bounds[0] + bounds[2] - w
    max_y = bounds[1] + bounds[3] - h
    if max_x >= bounds[0]:
        x = min(max(x, bounds[0]), max_x)
    else:
        x = bounds[0]
    if max_y >= bounds[1]:
        y = min(max(y, bounds[1]), max_y)
    else:
        y = bounds[1]
    return (snap(x, scale), snap(y, scale), w, h)


def distance_squared(point, rect) -> float:
    px, py = point
    x, y, w, h = rect
    if px < x:
        dx = x - px
    elif px > x + w:
        dx = px - (x + w)
    else:
        dx = 0
    if py < y:
        dy = y - py
    elif py > y + h:
        dy = py - (y + h)
    else:
        dy = 0
    return dx * dx + dy * dy


def screen_containing(mouse, screens):
    for screen in screens:
        x, y, w, h = screen["frame"]
        if x <= mouse[0] <= x + w and y <= mouse[1] <= y + h:
            return screen
    return min(screens, key=lambda s: distance_squared(mouse, s["frame"]))


def test_versions() -> None:
    assert is_version_newer("0.1.1", "0.1.0")
    assert is_version_newer("0.2.0", "0.1.9")
    assert is_version_newer("1.0.0", "0.9.9")
    assert is_version_newer("v0.1.1", "0.1.0")
    assert not is_version_newer("0.1.0", "0.1.0")
    assert not is_version_newer("0.1.0", "0.1.1")
    assert not is_version_newer("0.1.0", "0.1")
    print("OK version compare")


def test_gate() -> None:
    assert not should_show(5, 5, [], -1)
    assert should_show(6, 5, ["public.utf8-plain-text"], -1)
    assert should_show(6, 5, ["public.png"], -1)
    assert not should_show(6, 5, [MARKER, "public.utf8-plain-text"], -1)
    assert not should_show(6, 5, ["public.utf8-plain-text"], 6)
    assert should_show(7, 5, ["public.utf8-plain-text"], 6)
    assert not should_show(11, 10, ["public.tiff"], 2**31)
    print("OK copy effect gate")


def test_chord() -> None:
    chord = Chord()
    fired = chord.note_key_down(True, False, 4, 10.0)
    assert fired is None
    assert chord.note_key_up(True, 10.2) == 4

    chord.note_key_down(False, False, 9, 1)
    assert chord.note_key_up(True, 1.1) is None

    assert not is_plain_command_c(8, True, True, False, False, False)
    assert not is_plain_command_c(8, True, False, True, False, False)
    assert not is_plain_command_c(8, True, False, False, True, False)
    assert not is_plain_command_c(8, False, False, False, False, False)
    assert not is_plain_command_c(8, True, False, False, False, True)
    assert not is_plain_command_c(9, True, False, False, False, False)
    assert is_plain_command_c(8, True, False, False, False, False)

    chord = Chord()
    chord.note_key_down(True, False, 3, 0)
    assert chord.note_key_up(True, ARM_TIMEOUT + 0.01) is None

    chord = Chord()
    chord.note_key_down(True, False, 1, 0)
    chord.note_key_down(True, False, 8, 0.2)
    assert chord.note_key_up(True, 0.4) == 8
    print("OK chord state (effect only on key-up)")


def test_geometry() -> None:
    size = (320.0, 240.0)
    screen = (0.0, 0.0, 1440.0, 900.0)
    assert panel_frame((720, 450), size, screen, screen, 2) == (560.0, 378.0, 320.0, 240.0)
    assert panel_frame((10, 10), size, screen, screen, 2) == (0.0, 0.0, 320.0, 240.0)
    # Left of the primary display. Clamp to that screen, snap with its scale.
    left = (-1920.0, 0.0, 1920.0, 1080.0)
    assert panel_frame((-100, 500), size, left, left, 2) == (-320.0, 428.0, 320.0, 240.0)
    assert panel_frame((200.1, 400), size, screen, screen, 2)[0] == 40.0
    # Empty visibleFrame falls back to the full frame.
    assert panel_frame((720, 450), size, screen, (0, 0, 0, 0), 2) == (560.0, 378.0, 320.0, 240.0)

    screens = [
        {"frame": (0, 0, 1000, 800), "scale": 2},
        {"frame": (-1920, 0, 1920, 1080), "scale": 1},
    ]
    hit = screen_containing((-10, 10), screens)
    assert hit["scale"] == 1
    far = screen_containing((5000, 5000), screens)
    assert far["frame"][0] == 0
    print("OK screen geometry")


def test_versions_in_project() -> None:
    text = (ROOT / "iPaste.xcodeproj" / "project.pbxproj").read_text()
    marketing = re.findall(r"MARKETING_VERSION = ([^;]+);", text)
    builds = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)
    assert marketing == ["0.1.0", "0.1.0"] or (len(marketing) == 2 and len(set(marketing)) == 1)
    assert len(marketing) == 2 and len(set(marketing)) == 1
    assert len(builds) == 2 and len(set(builds)) == 1
    assert "ENABLE_APP_SANDBOX = NO;" in text
    assert "ENABLE_HARDENED_RUNTIME = NO;" in text
    assert "PRODUCT_BUNDLE_IDENTIFIER = io.github.bianyanhui.iPaste;" in text
    assert "com.apple.security.app-sandbox" not in text
    plist = (ROOT / "Support" / "Info.plist").read_text()
    assert "<key>LSUIElement</key>" in plist
    assert "<true/>" in plist
    assert "$(MARKETING_VERSION)" in plist
    assert "$(CURRENT_PROJECT_VERSION)" in plist
    assert "NSAccessibilityUsageDescription" not in plist
    assert "NSInputMonitoringUsageDescription" in plist
    print("OK version bump + LSUIElement + no sandbox")


def test_stage_flow() -> None:
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        payload = td_path / "payload"
        make_fake_app(payload, "0.2.0")
        zip_path = td_path / "iPaste.zip"
        with zipfile.ZipFile(zip_path, "w") as zf:
            for f in payload.rglob("*"):
                if f.is_file():
                    zf.write(f, f.relative_to(payload))
        unzipped = td_path / "unzipped"
        unzipped.mkdir()
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(unzipped)
        apps = list(unzipped.rglob("iPaste.app"))
        assert len(apps) == 1
        info = plistlib.loads((apps[0] / "Contents" / "Info.plist").read_bytes())
        assert info["CFBundleIdentifier"] == "io.github.bianyanhui.iPaste"
        assert is_version_newer(info["CFBundleShortVersionString"], "0.1.0")
        running = td_path / "Running"
        make_fake_app(running, "0.1.0")
        assert (running / "iPaste.app").exists()
        print("OK stage flow (running bundle untouched)")


def make_fake_app(dest: Path, version: str) -> None:
    app = dest / "iPaste.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    exe = macos / "iPaste"
    exe.write_text("#!/bin/sh\necho ipaste\n")
    exe.chmod(0o755)
    (app / "Contents" / "Info.plist").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.bianyanhui.iPaste</string>
  <key>CFBundleShortVersionString</key><string>%s</string>
</dict></plist>
"""
        % version
    )


def test_updater_source() -> None:
    src = (ROOT / "iPaste" / "AppUpdater.swift").read_text()
    assert "nohup" in src
    assert "IPASTE_UPDATER_PID" in src
    assert "IPASTE_UPDATER_SRC" in src
    assert "IPASTE_UPDATER_DST" in src
    assert "IPASTE_UPDATER_RUNNING" in src
    assert "sleep 1.5" in src
    assert "/usr/bin/nohup /bin/bash" in src
    assert "$1" in src
    assert "nonisolated private static func stageDownloadedUpdate" in src
    assert "nonisolated private static func launchReplacementScript" in src
    assert "posixPermissions" in src
    assert "waitUntilExit" in src
    assert "Task.detached" in src
    assert 'expectedBundleID = "io.github.bianyanhui.iPaste"' in src
    assert 'assetName = "iPaste.zip"' in src
    assert "--sign -" not in src
    assert "codesign --force --deep --sign -" not in src
    assert "/AppTranslocation/" in src
    assert "/var/folders/" in src
    print("OK updater waits for exit and keeps the CI signature")


def test_copy_and_overlay_contract() -> None:
    monitor = (ROOT / "iPaste" / "CopyChordMonitor.swift").read_text()
    assert ".listenOnly" in monitor
    assert "CGPreflightListenEventAccess" in monitor
    assert "CGRequestListenEventAccess" in monitor
    assert "NSEvent.mouseLocation" in monitor
    assert "scheduleConfirm" in monitor
    assert "AXIsProcessTrusted" not in monitor
    assert "addGlobalMonitor" not in monitor
    assert "addLocalMonitor" not in monitor
    key_up = monitor.index("if type == .keyUp")
    key_down = monitor.index("if type == .keyDown")
    assert key_down < key_up
    down_chunk = monitor[key_down:key_up]
    up_chunk = monitor[key_up : key_up + 700]
    assert "scheduleConfirm" not in down_chunk
    assert "present(" not in down_chunk
    assert "scheduleConfirm" in up_chunk

    panel = (ROOT / "iPaste" / "CritPanel.swift").read_text()
    assert ".nonactivatingPanel" in panel
    assert "ignoresMouseEvents = true" in panel
    assert "canBecomeKey: Bool { false }" in panel
    assert "canBecomeMain: Bool { false }" in panel
    assert "orderFrontRegardless()" in panel

    overlay = (ROOT / "iPaste" / "CritOverlayController.swift").read_text()
    assert "backingScaleFactor" in overlay
    assert "orderFrontRegardless()" in overlay
    assert "NSApp.activate" not in overlay
    assert "makeKeyAndOrderFront" not in overlay

    geometry = (ROOT / "iPaste" / "ScreenGeometry.swift").read_text()
    assert "backingScaleFactor" in geometry
    assert "toNearestOrAwayFromZero" in geometry

    sources = "\n".join(p.read_text() for p in (ROOT / "iPaste").glob("*.swift"))
    assert "AXIsProcessTrusted" not in sources
    assert "kAXTrustedCheckOptionPrompt" not in sources
    assert "NSApp.activate" not in sources
    print("OK ⌘C key-up, listen-only tap, nonactivating overlay")


def test_ci_signing() -> None:
    workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text()
    assert "IPASTE_SIGNING_CERTIFICATE_P12" in workflow
    assert "IPASTE_SIGNING_CERTIFICATE_PASSWORD" in workflow
    assert 'IPASTE_SIGN_IDENTITY: "iPaste Self-Signed"' in workflow
    assert "iPaste.zip" in workflow
    assert "Refusing to publish an ad-hoc" in workflow
    assert 'GITHUB_REF_TYPE}" = "tag"' in workflow or 'GITHUB_REF_TYPE}" = "tag"' in workflow
    docs = (ROOT / "docs" / "CODE_SIGNING.md").read_text()
    assert "IPASTE_SIGNING_CERTIFICATE_P12" in docs
    assert "IPASTE_SIGNING_CERTIFICATE_PASSWORD" in docs
    assert "iPaste Self-Signed" in docs
    assert "YOUR_P12_PASSWORD" in docs
    readme = (ROOT / "README.md").read_text()
    assert "IPASTE_SIGNING_CERTIFICATE_P12" in readme
    assert "输入监视" in readme
    assert "辅助功能" in readme
    print("OK CI signing secrets documented, tag builds reject ad-hoc")


def test_icons() -> None:
    icon_dir = ROOT / "iPaste" / "Assets.xcassets" / "AppIcon.appiconset"
    names = [
        "icon_16x16.png",
        "icon_16x16@2x.png",
        "icon_32x32.png",
        "icon_32x32@2x.png",
        "icon_128x128.png",
        "icon_128x128@2x.png",
        "icon_256x256.png",
        "icon_256x256@2x.png",
        "icon_512x512.png",
        "icon_512x512@2x.png",
    ]
    for name in names:
        data = (icon_dir / name).read_bytes()
        assert data.startswith(b"\x89PNG\r\n\x1a\n"), name
        assert len(data) > 32
    print("OK app icon pngs")


def test_ephemeral_rules_present() -> None:
    src = (ROOT / "iPaste" / "AppUpdater.swift").read_text()
    for prefix in ("/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/"):
        assert prefix in src
    print("OK ephemeral install locations")


def main() -> None:
    test_versions()
    test_gate()
    test_chord()
    test_geometry()
    test_versions_in_project()
    test_stage_flow()
    test_updater_source()
    test_copy_and_overlay_contract()
    test_ci_signing()
    test_icons()
    test_ephemeral_rules_present()
    print("ALL SELFTESTS PASSED")


if __name__ == "__main__":
    main()
