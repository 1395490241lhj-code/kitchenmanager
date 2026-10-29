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


def app_artifacts(app):
    paths = [app / "KitchenManager", *sorted(app.glob("*.dylib"))]
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def load_payload(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            assert key not in result, ("duplicate JSON key", key)
            result[key] = value
        return result
    def invalid(value):
        raise AssertionError(("nonfinite JSON number", value))
    return json.loads(text, object_pairs_hook=unique, parse_constant=invalid)


def scope(payload):
    version = payload["version"]
    assert type(version) is int and version in [1, 2, 3]
    for row in payload["preparedComponents"]:
        if version < 3:
            assert "lifecycle" not in row, "historical original contains lifecycle"
            if version == 1: assert "grouping" not in row
        else:
            assert "lifecycle" in row, "v3 original missing lifecycle"
            leaf = row["lifecycle"]
            if leaf is not None:
                assert isinstance(leaf, dict)
                assert set(leaf) == {"version", "thawPhase", "thawStartedAt", "thawCompletedAt", "cookedAt"}
                assert type(leaf["version"]) is int and leaf["version"] == 1
    result = {"weeklyPlan": payload["weeklyPlan"]}
    for key in DOMAINS:
        if key == "weeklyPlan":
            continue
        rows = payload[key]
        result[key] = {row["id"]: row for row in rows}
        assert len(rows) == len(result[key]), ("duplicate UUID", key)
    return result


def pr3_scope(payload):
    scope(payload)  # Qualify original version/shape/UUIDs before historical normalization.
    result = {key: copy.deepcopy(payload[key]) for key in DOMAINS}
    if payload["version"] < 3:
        for row in result["preparedComponents"]: row["lifecycle"] = None
    return result


def expected_pr3_mutation(before, operation):
    result = copy.deepcopy(before)
    rows = result["preparedComponents"]
    index = next(i for i, row in enumerate(rows) if row["id"] == "99000000-0000-0000-0000-000000000001")
    row = rows[index]
    event = 300 - 978307200  # Fixed Unix event mapped to Foundation's reference epoch.
    if operation == "begin-thaw":
        row["storage"] = "refrigerated"
        row["lifecycle"] = dict(version=1, thawPhase="thawing", thawStartedAt=event, thawCompletedAt=None, cookedAt=None)
    elif operation == "complete-thaw": row["lifecycle"].update(thawPhase="inactive", thawCompletedAt=event)
    elif operation == "mark-cooked": row["state"] = "cooked"; row["lifecycle"]["cookedAt"] = event
    elif operation == "split-thawing":
        row["portionsRemaining"] -= 1
        sibling = copy.deepcopy(row)
        sibling.update(id="99000000-0000-0000-0000-000000000002", portionsRemaining=1)
        rows.insert(index + 1, sibling)
    elif operation == "consume-final":
        assert row["portionsRemaining"] == 1
        rows.pop(index)
    else: raise AssertionError(operation)
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


def run(app, evidence, restore_only=False, suite="pr2"):
    assert os.environ.get("DEV_SIM_SLOT_AGENT") == "codex"
    assert os.environ.get("DEV_SIM_SLOT_UDID") == UDID, "whole-flow Codex lease required"
    assert app.name == "KitchenManager.app" and app.is_dir()
    evidence.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    def inputs():
        paths = list((root / "ios-native").rglob("*.swift"))
        paths += [p for p in (root / "ios-native/Kitchen Manager/KitchenManagerTests/Fixtures").rglob("*") if p.is_file()]
        paths += [p for p in (root / "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj").rglob("*") if p.is_file() and p.suffix in [".pbxproj", ".xcscheme", ".resolved"]]
        paths += [Path(__file__).resolve(), root / "scripts/test_pr3_process_acceptance.py"]
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(paths))}
    bound_inputs = inputs()
    (evidence / "inputs.json").write_text(json.dumps(bound_inputs, indent=2))
    shutil.copy2(app / "KitchenManager", evidence / "producer-KitchenManager")
    artifacts = app_artifacts(app)
    (evidence / "producer-artifacts").mkdir()
    for name in artifacts: shutil.copy2(app / name, evidence / "producer-artifacts" / name)
    (evidence / "app-artifacts.json").write_text(json.dumps(artifacts, indent=2))
    subprocess.run(["xcrun", "simctl", "install", UDID, str(app)], check=True, capture_output=True)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", UDID, BUNDLE, "data"], text=True).strip())
    installed = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", UDID, BUNDLE, "app"], text=True).strip())
    assert app_artifacts(installed) == artifacts, "installed executable/dylibs differ from producer"
    compare = pr3_scope if suite == "pr3" else scope
    receipts = []

    def launch(session, action, folder):
        directory = container / "tmp" / ("PreparedGroupingUI-" + session)
        env = dict(os.environ, SIMCTL_CHILD_PREPARED_GROUPING_SESSION=session, SIMCTL_CHILD_PREPARED_PROCESS_ACTION=action)
        started = time.time()
        launched = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, BUNDLE,
            "UITEST_PREPARED_GROUPING"], env=env, capture_output=True, text=True, timeout=25)
        match = re.search(re.escape(BUNDLE) + r": (\d+)", launched.stdout)
        assert launched.returncode == 0 and match, (launched.returncode, launched.stdout, launched.stderr)
        pid = int(match.group(1))
        name = "checkpoint.json" if action.endswith(("-before", "-after")) else "result.json"
        path = directory / name

        def report():
            if not path.exists():
                return None
            value = load_payload(path.read_text())
            return value if value["pid"] == pid and value["action"] == action and value["session"] == session else None

        value = wait_until(report)
        assert pid not in [entry["pid"] for entry in receipts], "launch must be a distinct process"
        entry = dict(action=action, pid=pid, session=session, directory=str(directory), started=started,
            launch_returncode=launched.returncode, launch_stdout=launched.stdout, launch_stderr=launched.stderr)
        if name == "checkpoint.json":
            state = wait_until(lambda: process_state(pid) if process_state(pid).startswith("T") else None)
            assert str(installed / "KitchenManager") in state, state
            entry.update(stopped_state=state, boundary=value["boundary"], verified_SIGSTOP=True, signal_sent="SIGKILL")
            os.kill(pid, signal.SIGKILL)
        wait_until(lambda: not process_state(pid) or process_state(pid).startswith("Z"))
        entry.update(terminated=True, finished=time.time(), report=value)
        receipts.append(entry)
        (folder / (str(len(receipts)) + "-" + action + ".json")).write_text(json.dumps(entry, indent=2, ensure_ascii=False))
        return directory, value

    try:
        operations = ["begin-thaw", "complete-thaw", "mark-cooked", "split-thawing", "consume-final"] if suite == "pr3" else ["create", "split", "consume"]
        for operation in ([] if restore_only else operations):
            for boundary in ["before", "after"]:
                case = operation + "-" + boundary
                folder = evidence / case
                folder.mkdir()
                session = str(uuid.uuid4()).upper()
                directory, seeded = launch(session, "pr3-seed-" + operation if suite == "pr3" else "seed", folder)
                baseline = load_payload((directory / "baseline.json").read_text())
                candidate = load_payload((directory / "candidate.json").read_text())
                assert compare(seeded["payload"]) == compare(baseline)
                directory, stopped = launch(session, "pr3-" + case if suite == "pr3" else case, folder)
                assert stopped["boundary"] == ("before-save" if boundary == "before" else "after-commit-before-publication")
                assert compare(stopped["payload"]) == compare(baseline), "publication happened before cutpoint"
                assert not stopped["outstandingRecovery"]
                expected = baseline if boundary == "before" else (expected_pr3_mutation(baseline, operation) if suite == "pr3" else expected_mutation(baseline, candidate, operation))
                (folder / "expected.json").write_text(json.dumps(expected, indent=2, ensure_ascii=False))
                (folder / "baseline.json").write_bytes((directory / "baseline.json").read_bytes())
                for store_file in directory.glob("kitchen.store*"):
                    shutil.copy2(store_file, folder / store_file.name)
                for _ in range(2):
                    _, restarted = launch(session, "probe", folder)
                    assert compare(restarted["payload"]) == compare(expected), (case, restarted, expected)
                    prepared_ids(restarted["payload"])
                    assert restarted["outcome"] == "nil" and not restarted["outstandingRecovery"]
                print(case, "PASS", flush=True)

        restores = ["import-v3", "recovery-v3", "recovery-v1", "recovery-v2"] if suite == "pr3" else ["import-v3", "recovery-v1"]
        for mode in restores:
            historical = mode != "import-v3"
            case = mode
            folder = evidence / case
            folder.mkdir()
            session = str(uuid.uuid4()).upper()
            directory, _ = launch(session, "pr3-seed-" + mode if suite == "pr3" else ("seed-v1" if historical else "seed"), folder)
            baseline = load_payload((directory / "baseline.json").read_text())
            candidate = load_payload((directory / "candidate.json").read_text())
            before, target = (candidate, baseline) if historical else (baseline, candidate)
            _, stopped = launch(session, ("pr3-" if suite == "pr3" else "") + ("recovery-after" if historical else "restore-after"), folder)
            assert stopped["boundary"] == "after-commit-before-publication"
            assert compare(stopped["payload"]) == compare(before)
            assert stopped["outstandingRecovery"] and stopped["outcome"] == "nil"
            recovery = directory / "recovery/pre-restore-recovery.json"
            saved = recovery.read_bytes()
            assert load_payload(saved)["version"] == (int(mode[-1]) if historical else 3)
            assert compare(load_payload(saved)) == compare(baseline)
            (folder / "retained-recovery.json").write_bytes(saved)
            (folder / "baseline.json").write_bytes((directory / "baseline.json").read_bytes())
            (folder / "candidate.json").write_bytes((directory / "candidate.json").read_bytes())
            for store_file in directory.glob("kitchen.store*"):
                shutil.copy2(store_file, folder / store_file.name)
            mixed = compare(target)
            mixed["specialPlans"] = compare(before)["specialPlans"]
            assert mixed != compare(before) and mixed != compare(target), "not an interrupted multi-domain state"
            for _ in range(2):
                _, restarted = launch(session, "probe", folder)
                assert compare(restarted["payload"]) == mixed
                assert restarted["outstandingRecovery"] and restarted["outcome"] == "nil"
                assert recovery.read_bytes() == saved, "recovery changed or automatically replayed"
            _, blocked = launch(session, "blocked", folder)
            assert compare(blocked["payload"]) == mixed and blocked["outstandingRecovery"]
            assert "preparationFailed" in blocked["outcome"] and recovery.read_bytes() == saved
            _, recovered = launch(session, "recover", folder)
            assert "success" in recovered["outcome"] and not recovered["outstandingRecovery"]
            for _ in range(2):
                _, restarted = launch(session, "probe", folder)
                assert compare(restarted["payload"]) == compare(baseline)
                assert not restarted["outstandingRecovery"] and restarted["outcome"] == "nil"
            (folder / "recovery-integrity.json").write_text(json.dumps({"version": json.loads(saved)["version"],
                "sha256": hashlib.sha256(saved).hexdigest(), "explicit_recovery_verified": True}, indent=2))
            print(case, "PASS (six committed domains; seventh remains old; explicit recovery)", flush=True)
        (evidence / "summary.json").write_text(json.dumps({"suite": suite, ("A10" if suite == "pr3" else "A13"): "NOT_RUN" if restore_only else "PASS", ("A11" if suite == "pr3" else "A14"): "PASS", "cases": len(restores) + (0 if restore_only else 2 * len(operations)),
            "terminations": sum(x.get("signal_sent") == "SIGKILL" for x in receipts),
            "launches": len(receipts), "cross_domain_atomicity": False}, indent=2))
    finally:
        (evidence / "process-receipts.json").write_text(json.dumps(receipts, indent=2, ensure_ascii=False))
        assert bound_inputs == inputs(), "source/fixture/runner changed during process flow"
        assert app_artifacts(app) == artifacts and app_artifacts(installed) == artifacts, "app code changed during process flow"
        (evidence / "source-bound.json").write_text(json.dumps({"suite": suite, "source_unchanged": True,
            "inputs_sha256": hashlib.sha256((evidence / "inputs.json").read_bytes()).hexdigest(),
            "app_binary_sha256": hashlib.sha256((evidence / "producer-KitchenManager").read_bytes()).hexdigest(),
            "app_code_artifacts": artifacts,
            "owner": "codex", "udid": UDID}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--restore-only", action="store_true", help="Run only the two interrupted-restore cases")
    parser.add_argument("--suite", choices=["pr2", "pr3"], default="pr2")
    args = parser.parse_args()
    run(args.app.resolve(), args.evidence.resolve(), args.restore_only, args.suite)
