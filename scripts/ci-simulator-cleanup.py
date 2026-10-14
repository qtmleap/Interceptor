import json, os, pathlib, subprocess, sys, time, uuid
import signal

def stop_host_build():
    path = pathlib.Path(os.environ["RUNNER_TEMP"]) / "simulator-build-group.json"
    if not path.exists():
        return
    record = json.loads(path.read_text())
    if record.get("stopped"):
        return
    pid, group = record["pid"], record["pgid"]
    if pid != group or group <= 1 or record["run_id"] != os.environ.get("GITHUB_RUN_ID", "local"):
        raise SystemExit("Refusing an unverified build process group")
    leader = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True)
    def live_group():
        result = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="], check=True, capture_output=True, text=True)
        return any(int(parts[1]) == group and not parts[2].startswith("Z")
                   for line in result.stdout.splitlines() if len(parts := line.split()) >= 3)
    if live_group():
        if leader.returncode == 0 and leader.stdout.strip() != record["started"]:
            raise SystemExit("Build process identity changed; refusing to stop it")
        if leader.returncode != 0:
            anchor = record.get("anchor_pid")
            identity = subprocess.run(["ps", "-p", str(anchor), "-o", "lstart="], capture_output=True, text=True) if anchor else None
            try:
                matches = identity is not None and identity.returncode == 0 and identity.stdout.strip() == record.get("anchor_started") and os.getpgid(anchor) == group
            except ProcessLookupError:
                matches = False
            if not matches:
                raise SystemExit("Build leader and session anchor are unavailable; refusing an uncertain group")
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(100):
            if not live_group():
                break
            time.sleep(0.1)
        if live_group():
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for _ in range(20):
            if not live_group():
                break
            time.sleep(0.1)
        if live_group():
            raise SystemExit("Owned build group remains active; simulator cleanup aborted")
    record["stopped"] = True
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record))
    temporary.replace(path)

stop_host_build()
if "--stop-worker" in sys.argv:
    raise SystemExit(0)

device = os.environ.get("SIMULATOR_UUID", "")
if not device:
    snapshot = pathlib.Path(os.environ["RUNNER_TEMP"]) / "simulators-before.json"
    if snapshot.exists() and "CI_SIMULATOR_DEVICE_SET" in os.environ:
        before_ids = {d["udid"] for group in json.loads(snapshot.read_text())["devices"].values() for d in group}
        result = subprocess.run(["xcrun", "simctl", "--set", os.environ["CI_SIMULATOR_DEVICE_SET"], "list", "devices", "--json"], check=True, capture_output=True, text=True)
        unknown = [d["udid"] for group in json.loads(result.stdout)["devices"].values() for d in group
                   if d["name"] == "Interceptor CI" and d["udid"] not in before_ids]
        if unknown:
            raise SystemExit("Simulator UUID was not recorded; ownership is uncertain. Devices left untouched: " + ", ".join(unknown))
    raise SystemExit(0)
if str(uuid.UUID(device)).lower() != device.lower():
    raise SystemExit("Invalid owned simulator UUID")
before = json.loads((pathlib.Path(os.environ["RUNNER_TEMP"]) / "simulators-before.json").read_text())["devices"]
if any(d["udid"] == device for devices in before.values() for d in devices):
    raise SystemExit("Refusing to delete a pre-existing simulator")
command = ["xcrun", "simctl", "--set", os.environ["CI_SIMULATOR_DEVICE_SET"]]
def devices():
    result = subprocess.run(command + ["list", "devices", "--json"], check=True, capture_output=True, text=True)
    return [d for group in json.loads(result.stdout)["devices"].values() for d in group]
owned = next((d for d in devices() if d["udid"] == device), None)
if owned is not None:
    if owned["name"] != "Interceptor CI":
        raise SystemExit("Owned simulator name does not match this job")
    subprocess.run(command + ["shutdown", device], check=False)
    for attempt in range(3):
        deleted = subprocess.run(command + ["delete", device], check=False)
        if deleted.returncode == 0:
            break
        time.sleep(1)
    deleted.check_returncode()
if any(d["udid"] == device for d in devices()):
    raise SystemExit("Owned simulator remains after cleanup")
print("Owned simulator cleanup verified:", device)
