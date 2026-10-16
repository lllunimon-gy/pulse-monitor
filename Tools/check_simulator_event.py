#!/usr/bin/env python3
"""Wait for a real example-app stall to recover and reach its on-device archive."""
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
deadline = time.monotonic() + 90
last_events = []
while time.monotonic() < deadline:
    try:
        events = json.loads(path.read_text())
        last_events = events
        for event in events:
            if (event["phase"] == "recovered"
                    and event.get("endedAtUptime") is not None
                    and any(item["message"] == "main-sleep" for item in event["breadcrumbs"])):
                assert event["duration"] >= 0.25
                assert event["evidence"]["source"] == "local-runloop-proxy"
                print("Observed recovered main-sleep event with preserved evidence and probe end time.")
                raise SystemExit(0)
    except (OSError, json.JSONDecodeError):
        pass
    time.sleep(0.5)
print("Archive exists:", path.exists())
state = path.parent / "smoke-status.json"
print("Experiment state:", state.read_text() if state.exists() else "missing")
print("Observed event phases:", [item.get("phase") for item in last_events])
print("Observed breadcrumbs:", [[crumb.get("message") for crumb in item.get("breadcrumbs", [])]
                                for item in last_events[-5:]])
raise SystemExit("No recovered main-sleep event persisted within 90 seconds")
