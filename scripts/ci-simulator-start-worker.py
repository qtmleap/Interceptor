import json
import os
import pathlib
import signal
import subprocess
import sys

if len(sys.argv) < 2:
    raise SystemExit("A build command is required")
os.setsid()
pid = os.getpid()
started = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], check=True, capture_output=True, text=True).stdout.strip()
record = {"pid": pid, "pgid": os.getpgrp(), "started": started, "run_id": os.environ.get("GITHUB_RUN_ID", "local")}
path = pathlib.Path(os.environ["RUNNER_TEMP"]) / "simulator-build-group.json"
def save():
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record))
    temporary.replace(path)
save()
# Keep the session identifiable after xcodebuild exits but descendants remain.
anchor = os.fork()
if anchor == 0:
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    null = os.open(os.devnull, os.O_RDWR)
    for descriptor in (0, 1, 2):
        os.dup2(null, descriptor)
    os.closerange(3, 65536)
    while True:
        signal.pause()
record["anchor_pid"] = anchor
record["anchor_started"] = subprocess.run(["ps", "-p", str(anchor), "-o", "lstart="], check=True, capture_output=True, text=True).stdout.strip()
save()
os.execvp(sys.argv[1], sys.argv[1:])
