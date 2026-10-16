#!/usr/bin/env python3
"""Wait for a real example-app stall to recover and reach its on-device archive."""
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        events = json.loads(path.read_text())
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
raise SystemExit("No recovered main-sleep event persisted within 30 seconds")
