#!/usr/bin/env python3
"""Synthetic PR2 process-boundary assertions; run for the whole flow under dev-sim-slot."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import uuid

DOMAINS = ["inventory", "shoppingItems", "plans", "consumptionRecords", "weeklyPlan", "preparedComponents", "specialPlans"]
BUNDLE = "com.lianghongjing.kitchenmanager"
UDID = "18FAEFC5-3087-48A4-8131-5B97F48D62C6"


def scope(payload):
    result = {"weeklyPlan": payload["weeklyPlan"]}
    for key in DOMAINS:
        if key == "weeklyPlan":
            continue
        rows = payload[key]
        result[key] = {row["id"]: row for row in rows}
        assert len(rows) == len(result[key]), ("duplicate UUID", key)
    return result


def prepared_ids(payload):
    ids = [row["id"] for row in payload["preparedComponents"]]
    assert len(ids) == len(set(ids)), "duplicate Prepared UUID"
    return ids


def expected_mutation(before, candidate, operation):
    result = copy.deepcopy(before)
    rows = result["preparedComponents"]
    if operation == "create":
        rows.extend(row for row in candidate["preparedComponents"] if row.get("grouping"))
    elif operation == "split":
        original = next(row for row in rows if row["id"].endswith("000000000001"))
        original["portionsRemaining"] -= 1
        sibling = copy.deepcopy(original)
        sibling.update(id="99000000-0000-0000-0000-000000000002", portionsRemaining=1)
        rows.append(sibling)
    elif operation == "consume":
        next(row for row in rows if row["id"].endswith("000000000001"))["portionsRemaining"] -= 1
    else:
        raise AssertionError(operation)
    return result


def process_state(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "state=", "-o", "comm="], capture_output=True, text=True)
    return result.stdout.strip()


def wait_until(check, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("probe timed out")


def run(app, evidence, restore_only=False):
    assert os.environ.get("DEV_SIM_SLOT_AGENT") == "codex"
    assert os.environ.get("DEV_SIM_SLOT_UDID") == UDID, "whole-flow Codex lease required"
    assert app.name == "KitchenManager.app" and app.is_dir()
    evidence.mkdir(parents=True, exist_ok=False)
    subprocess.run(["xcrun", "simctl", "install", UDID, str(app)], check=True, capture_output=True)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", UDID, BUNDLE, "data"], text=True).strip())
    receipts = []

    def launch(session, action, folder):
        directory = container / "tmp" / ("PreparedGroupingUI-" + session)
        env = dict(os.environ, SIMCTL_CHILD_PREPARED_GROUPING_SESSION=session, SIMCTL_CHILD_PREPARED_PROCESS_ACTION=action)
        started = time.time()
        launched = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, BUNDLE,
            "UITEST_PREPARED_GROUPING"], env=env, capture_output=True, text=True, timeout=25)
        match = re.search(re.escape(BUNDLE) + r": (\d+)", launched.stdout)
        assert match, (launched.returncode, launched.stdout, launched.stderr)
        pid = int(match.group(1))
        name = "checkpoint.json" if action.endswith(("-before", "-after")) else "result.json"
        path = directory / name

        def report():
            if not path.exists():
                return None
            value = json.loads(path.read_text())
            return value if value["pid"] == pid and value["action"] == action and value["session"] == session else None

        value = wait_until(report)
        entry = dict(action=action, pid=pid, session=session, directory=str(directory), started=started,
            launch_returncode=launched.returncode, launch_stdout=launched.stdout, launch_stderr=launched.stderr)
        if name == "checkpoint.json":
            state = wait_until(lambda: process_state(pid) if process_state(pid).startswith("T") else None)
            assert "/KitchenManager.app/KitchenManager" in state, state
            entry.update(stopped_state=state, boundary=value["boundary"], signal_sent="SIGKILL")
            os.kill(pid, signal.SIGKILL)
        wait_until(lambda: not process_state(pid) or process_state(pid).startswith("Z"))
        entry.update(terminated=True, finished=time.time(), report=value)
        receipts.append(entry)
        (folder / (str(len(receipts)) + "-" + action + ".json")).write_text(json.dumps(entry, indent=2, ensure_ascii=False))
        return directory, value

    try:
        for operation in ([] if restore_only else ["create", "split", "consume"]):
            for boundary in ["before", "after"]:
                case = operation + "-" + boundary
                folder = evidence / case
                folder.mkdir()
                session = str(uuid.uuid4()).upper()
                directory, seeded = launch(session, "seed", folder)
                baseline = json.loads((directory / "baseline.json").read_text())
                candidate = json.loads((directory / "candidate.json").read_text())
                assert scope(seeded["payload"]) == scope(baseline)
                directory, stopped = launch(session, case, folder)
                assert scope(stopped["payload"]) == scope(baseline), "publication happened before cutpoint"
                assert not stopped["outstandingRecovery"]
                expected = baseline if boundary == "before" else expected_mutation(baseline, candidate, operation)
                for store_file in directory.glob("kitchen.store*"):
                    shutil.copy2(store_file, folder / store_file.name)
                for _ in range(2):
                    _, restarted = launch(session, "probe", folder)
                    assert scope(restarted["payload"]) == scope(expected), (case, restarted, expected)
                    prepared_ids(restarted["payload"])
                    assert restarted["outcome"] == "nil" and not restarted["outstandingRecovery"]
                print(case, "PASS", flush=True)

        for historical in [False, True]:
            case = "restore-v1-recovery" if historical else "restore-v2"
            folder = evidence / case
            folder.mkdir()
            session = str(uuid.uuid4()).upper()
            directory, _ = launch(session, "seed-v1" if historical else "seed", folder)
            baseline = json.loads((directory / "baseline.json").read_text())
            candidate = json.loads((directory / "candidate.json").read_text())
            before, target = (candidate, baseline) if historical else (baseline, candidate)
            _, stopped = launch(session, "recovery-after" if historical else "restore-after", folder)
            assert scope(stopped["payload"]) == scope(before)
            assert stopped["outstandingRecovery"] and stopped["outcome"] == "nil"
            recovery = directory / "recovery/pre-restore-recovery.json"
            saved = recovery.read_bytes()
            assert json.loads(saved)["version"] == (1 if historical else 2)
            assert scope(json.loads(saved)) == scope(baseline)
            (folder / "retained-recovery.json").write_bytes(saved)
            mixed = scope(target)
            mixed["specialPlans"] = scope(before)["specialPlans"]
            assert mixed != scope(before) and mixed != scope(target), "not an interrupted multi-domain state"
            for _ in range(2):
                _, restarted = launch(session, "probe", folder)
                assert scope(restarted["payload"]) == mixed
                assert restarted["outstandingRecovery"] and restarted["outcome"] == "nil"
                assert recovery.read_bytes() == saved, "recovery changed or automatically replayed"
            _, blocked = launch(session, "blocked", folder)
            assert scope(blocked["payload"]) == mixed and blocked["outstandingRecovery"]
            assert "preparationFailed" in blocked["outcome"] and recovery.read_bytes() == saved
            _, recovered = launch(session, "recover", folder)
            assert "success" in recovered["outcome"] and not recovered["outstandingRecovery"]
            for _ in range(2):
                _, restarted = launch(session, "probe", folder)
                assert scope(restarted["payload"]) == scope(baseline)
                assert not restarted["outstandingRecovery"] and restarted["outcome"] == "nil"
            (folder / "recovery-integrity.json").write_text(json.dumps({"version": json.loads(saved)["version"],
                "sha256": hashlib.sha256(saved).hexdigest(), "explicit_recovery_verified": True}, indent=2))
            print(case, "PASS (six committed domains; seventh remains old; explicit recovery)", flush=True)
        (evidence / "summary.json").write_text(json.dumps({"A13": "NOT_RUN" if restore_only else "PASS", "A14": "PASS", "cases": 2 if restore_only else 8,
            "terminations": sum(x.get("signal_sent") == "SIGKILL" for x in receipts),
            "launches": len(receipts), "cross_domain_atomicity": False}, indent=2))
    finally:
        (evidence / "process-receipts.json").write_text(json.dumps(receipts, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--restore-only", action="store_true", help="Run only the two interrupted-restore cases")
    args = parser.parse_args()
    run(args.app.resolve(), args.evidence.resolve(), args.restore_only)
