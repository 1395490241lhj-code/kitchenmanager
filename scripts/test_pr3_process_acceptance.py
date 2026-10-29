"""Focused host-oracle checks; no simulator or application process is launched."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location("process_acceptance", Path(__file__).with_name("pr2-process-acceptance.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PR3ProcessOracleTests(unittest.TestCase):
    def testArtifactBindingIncludesTheLoadedDebugDylib(self):
        with tempfile.TemporaryDirectory(prefix="km-pr3-artifact-oracle-") as root:
            app = Path(root) / "KitchenManager.app"; app.mkdir()
            (app / "KitchenManager").write_bytes(b"launcher")
            (app / "KitchenManager.debug.dylib").write_bytes(b"actual app code")
            artifacts = runner.app_artifacts(app)
            self.assertEqual(set(artifacts), {"KitchenManager", "KitchenManager.debug.dylib"})
            old = dict(artifacts)
            (app / "KitchenManager.debug.dylib").write_bytes(b"changed actual code")
            self.assertNotEqual(runner.app_artifacts(app), old)
            self.assertEqual(runner.app_artifacts(app)["KitchenManager"], old["KitchenManager"])

    def payload(self):
        row = {"id": "99000000-0000-0000-0000-000000000001", "portionsRemaining": 1,
               "state": "prepped", "storage": "frozen", "expiryDate": 100000 - 978307200,
               "preparedAt": 100 - 978307200, "name": "鸡肉", "lifecycle": None}
        return dict(version=3, weeklyPlan=None, preparedComponents=[row],
                    **{k: [] for k in runner.DOMAINS if k not in ["weeklyPlan", "preparedComponents"]})

    def testOriginalLifecycleCompletenessCannotBeNormalizedIntoValidity(self):
        for version in [1, 2, 3]:
            value = self.payload(); value["version"] = version
            if version == 3: del value["preparedComponents"][0]["lifecycle"]
            with self.subTest(version=version), self.assertRaises(AssertionError): runner.scope(value)
        value = self.payload(); value["preparedComponents"][0]["lifecycle"] = {"version": 2}
        with self.assertRaises(AssertionError): runner.scope(value)

    def testDuplicateJSONKeysAndUUIDsReject(self):
        with self.assertRaises(AssertionError): runner.load_payload('{"version":3,"version":2}')
        value = self.payload(); value["preparedComponents"] *= 2
        with self.assertRaises(AssertionError): runner.scope(value)

    def testExpectedMutationUsesFixedEventsAndPreservesSiblings(self):
        for op in ["begin-thaw", "complete-thaw", "mark-cooked", "split-thawing", "consume-final"]:
            before = self.payload(); row = before["preparedComponents"][0]
            row["storage"] = "refrigerated" if op != "begin-thaw" else "frozen"
            if op != "begin-thaw":
                row["lifecycle"] = dict(version=1, thawPhase="thawing", thawStartedAt=110 - 978307200,
                                        thawCompletedAt=None, cookedAt=None)
            if op in ["mark-cooked", "consume-final"]:
                row["lifecycle"].update(thawPhase="inactive", thawCompletedAt=150 - 978307200)
            if op == "consume-final": row["state"] = "cooked"; row["lifecycle"]["cookedAt"] = 200 - 978307200
            if op == "split-thawing": row["portionsRemaining"] = 2
            sibling = copy.deepcopy(row); sibling["id"] = "unrelated"
            before["preparedComponents"].append(sibling); saved = copy.deepcopy(before)
            changed = runner.expected_pr3_mutation(before, op)
            self.assertEqual(before, saved)
            self.assertEqual(changed["preparedComponents"][-1], sibling)
            if op == "begin-thaw": self.assertEqual(changed["preparedComponents"][0]["lifecycle"]["thawStartedAt"], 300 - 978307200)
            if op == "complete-thaw": self.assertEqual(changed["preparedComponents"][0]["lifecycle"]["thawCompletedAt"], 300 - 978307200)
            if op == "mark-cooked": self.assertEqual(changed["preparedComponents"][0]["lifecycle"]["cookedAt"], 300 - 978307200)
            if op == "split-thawing":
                self.assertEqual(changed["preparedComponents"][1]["lifecycle"], row["lifecycle"])
                self.assertEqual(changed["preparedComponents"][1]["expiryDate"], row["expiryDate"])
                self.assertEqual(changed["preparedComponents"][1]["id"], "99000000-0000-0000-0000-000000000002")
            if op == "consume-final": self.assertEqual(changed["preparedComponents"], [sibling])

    def testStrictPR3ScopePreservesOrderingAndQualifiesHistoricalNull(self):
        value = self.payload(); original = copy.deepcopy(value)
        other = copy.deepcopy(value["preparedComponents"][0]); other["id"] = "other"
        value["preparedComponents"].append(other)
        reverse = copy.deepcopy(value); reverse["preparedComponents"].reverse()
        self.assertNotEqual(runner.pr3_scope(value), runner.pr3_scope(reverse))
        for version in [1, 2]:
            old = copy.deepcopy(original); old["version"] = version
            del old["preparedComponents"][0]["lifecycle"]
            self.assertEqual(runner.pr3_scope(old), runner.pr3_scope(original))
            self.assertNotIn("lifecycle", old["preparedComponents"][0])


if __name__ == "__main__": unittest.main()
