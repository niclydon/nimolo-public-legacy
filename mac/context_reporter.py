#!/usr/bin/env python3
"""Mac context reporter for the Pets platform (Pets Next).

Classifies what Nic is doing ON THIS MAC and reports only
enums and numbers to pets-mcp's bus: frontmost app ->
app_class, HID idle time, a focus streak for the
coding/writing classes, and (v2) calendar pressure.

Calendar (v2): read through EventKitBridge, the signed
Mac helper that holds the EventKit grant (file protocol:
inbox/outbox JSON under ~/Library/Application
Support/EventKitBridge). The bridge payload includes
event titles; the reporter uses only start/end/all-day
in memory and discards the rest. Only two derived values
leave the Mac: next_meeting_min (minutes to the next
timed event) and calendar_pressure (low/medium/high from
event density in the next 4 hours). Refreshed at most
every 4 minutes and cached in the state file; on bridge
failure the cache is reused for up to 15 minutes and
confidence drops back to medium.

Run by LaunchAgent io.niclydon.nimolo-context every 30 s.
State lives in ~/.config/nimolo/context-state.json (the
Factotum pets-context service watches its freshness).
"""
import json
import os
import subprocess
import time
import urllib.request
import uuid
from datetime import datetime, timedelta
from pathlib import Path

CFG = Path.home() / ".config" / "nimolo"
STATE = CFG / "context-state.json"
BRIDGE = (Path.home() / "Library" / "Application Support"
          / "EventKitBridge")
# The coordinator's bus endpoint. Point it at your own
# coordinator: write the base URL to ~/.config/nimolo/bus-host
# or set NIMOLO_BUS_URL. Defaults to a local coordinator.
def _bus_base():
    host_file = CFG / "bus-host"
    if host_file.exists():
        saved = host_file.read_text().strip()
        if saved:
            return saved
    return os.environ.get("NIMOLO_BUS_URL", "http://127.0.0.1:7891")


BUS = _bus_base() + "/bus/publish"

CAL_TTL_S = 240        # refresh the calendar read at most this often
CAL_STALE_S = 900      # reuse a failed read's cache up to this age

APPS = {
    "coding": {"Xcode", "Code", "Visual Studio Code", "Cursor",
               "Terminal", "iTerm2", "Warp", "Ghostty",
               "IntelliJ IDEA", "PyCharm", "Sublime Text"},
    "writing": {"Pages", "Word", "Microsoft Word", "Notion",
                "Obsidian", "TextEdit", "Scrivener", "Ulysses",
                "Google Docs"},
    "meeting": {"zoom.us", "Zoom", "Microsoft Teams", "Webex",
                "FaceTime", "Slack", "Discord"},
    "browsing": {"Safari", "Google Chrome", "Firefox", "Arc",
                 "Microsoft Edge", "Brave Browser"},
    "media": {"TV", "Music", "QuickTime Player", "VLC",
              "Spotify", "Photos"},
}


def frontmost_app() -> str:
    try:
        out = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get name of '
             'first application process whose frontmost is true'],
            capture_output=True, text=True, timeout=8)
        return out.stdout.strip()
    except Exception:
        return ""


def idle_seconds() -> int:
    try:
        out = subprocess.run(["ioreg", "-c", "IOHIDSystem"],
                             capture_output=True, text=True,
                             timeout=8).stdout
        for line in out.splitlines():
            if "HIDIdleTime" in line:
                ns = int(line.rsplit("=", 1)[1].strip())
                return ns // 1_000_000_000
    except Exception:
        pass
    return 0


def classify(app: str, idle: int) -> str:
    if idle >= 600:
        return "away"
    if idle >= 120:
        return "idle"
    for cls, names in APPS.items():
        if app in names:
            return cls
    return "browsing" if app else "idle"


def _bridge_events(start: datetime, end: datetime):
    """One EventKitBridge round trip; returns the event
    list (times only are used) or None on any failure."""
    rid = uuid.uuid4().hex[:12]
    req = {"id": rid, "op": "events_in_range",
           "start_iso": start.isoformat(),
           "end_iso": end.isoformat()}
    inbox = BRIDGE / "inbox"
    outbox = BRIDGE / "outbox"
    try:
        inbox.mkdir(parents=True, exist_ok=True)
        (inbox / f"{rid}.json").write_text(json.dumps(req))
    except Exception:
        return None
    result = None
    deadline = time.time() + 8
    while time.time() < deadline:
        f = outbox / f"{rid}.json"
        if f.exists():
            try:
                result = json.loads(f.read_text())
            except Exception:
                result = None
            try:
                f.unlink()
            except Exception:
                pass
            break
        time.sleep(0.25)
    if not result or not result.get("ok"):
        return None
    return result.get("events") or []


def fetch_calendar(now: int):
    """(next_meeting_min, calendar_pressure) or None."""
    start = datetime.fromtimestamp(now).astimezone()
    events = _bridge_events(start - timedelta(hours=1),
                            start + timedelta(hours=12))
    if events is None:
        return None
    timed = []
    for e in events:
        if e.get("all_day"):
            continue
        try:
            s = datetime.fromisoformat(e["start_iso"])
            en = datetime.fromisoformat(e["end_iso"])
        except Exception:
            continue
        timed.append((s, en))
    timed.sort()
    nxt = None
    for s, en in timed:
        if s > start:
            nxt = int((s - start).total_seconds() // 60)
            break
    horizon = start + timedelta(hours=4)
    near = [(s, en) for s, en in timed if s < horizon and en > start]
    pressure = "low" if len(near) <= 1 else \
        "medium" if len(near) <= 3 else "high"
    for (s1, e1), (s2, e2) in zip(near, near[1:]):
        if (s2 - e1) < timedelta(minutes=15) and pressure == "low":
            pressure = "medium"
        elif (s2 - e1) < timedelta(minutes=15) and pressure == "medium":
            pressure = "high"
    return nxt, pressure


def main() -> int:
    app = frontmost_app()
    idle = idle_seconds()
    cls = classify(app, idle)
    now = int(time.time())
    try:
        prev = json.loads(STATE.read_text())
    except Exception:
        prev = {}
    focus = 0
    if cls in ("coding", "writing"):
        if prev.get("class") == cls and idle < 120:
            focus = int(prev.get("focus", 0)) + 1
    cal = prev.get("cal") or {}
    fresh = False
    if now - int(cal.get("at", 0)) >= CAL_TTL_S:
        got = fetch_calendar(now)
        if got is not None:
            cal = {"at": now, "next": got[0], "pressure": got[1]}
            fresh = True
    usable = bool(cal) and now - int(cal.get("at", 0)) <= CAL_STALE_S
    next_min = cal.get("next") if usable else None
    pressure = cal.get("pressure") if usable else "low"
    cal_age = now - int(cal.get("at", 0)) if cal else 10 ** 9
    confidence = "high" if usable and cal_age <= CAL_TTL_S \
        else "medium"
    state = {"class": cls, "focus": focus, "at": now, "cal": cal}
    try:
        CFG.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(state))
    except Exception:
        pass
    token = (CFG / "bus-token").read_text().strip()
    body = json.dumps({
        "type": "context", "app_class": cls,
        "idle_s": idle, "focus_min": focus,
        "next_meeting_min": next_min,
        "calendar_pressure": pressure,
        "confidence": confidence}).encode()
    req = urllib.request.Request(
        BUS, data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "X-Bus-Token": token})
    with urllib.request.urlopen(req, timeout=8) as r:
        return 0 if r.status == 200 else 1


if __name__ == "__main__":
    raise SystemExit(main())
