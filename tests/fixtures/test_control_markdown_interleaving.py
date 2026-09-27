"""Offline safety checks for the native typing control; no login or DB calls."""
import copy
import tempfile
from pathlib import Path
import unittest

import control_markdown_interleaving as control


class TypingControlTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = {"id": "00000000-0000-4000-8000-000000000012", "revision": "4", "kind": "md",
            "name": control.NAME, "parentId": "00000000-0000-4000-8000-000000000011", "state": "active",
            "markdownSource": control.BASE, "metadata": {"title": "synthetic", "future": 3}, "assets": [], "annotations": []}
        self.plan = control.make_plan(self.snapshot["id"], 4, self.snapshot, control.LOCAL_FINAL)

    def current(self, local, *, committed=False):
        value = copy.deepcopy(self.snapshot)
        value["revision"] = "9"  # Expected legitimate native autosave advancement.
        remote = self.plan["remoteMarker"] if committed else "base"
        value["markdownSource"] = "Remote: " + remote + "\n\n" + local + "\n\nTail: keep\n"
        return value

    def testAcceptsAdvancedRevisionWithOnlyAgreedLocalPrefixes(self):
        for n in range(len(control.LOCAL_BASE), len(control.LOCAL_FINAL) + 1):
            local = control.LOCAL_FINAL[:n]
            self.assertEqual(control.validate_current(self.plan, self.current(local)), local)

    def testRejectsUnrelatedTextOrNonAppendEdit(self):
        for local in ["Local: replaced", "Local: base-surprise", "Local: bas", "Local: base\nSecret: other"]:
            with self.subTest(local=local), self.assertRaises(RuntimeError):
                control.validate_current(self.plan, self.current(local))
        for before, after in [("Remote: base", "Remote: changed"), ("Tail: keep", "Tail: changed"), ("\n\nTail", "\nTail")]:
            value = copy.deepcopy(self.snapshot)
            value["markdownSource"] = value["markdownSource"].replace(before, after)
            with self.subTest(change=after), self.assertRaises(RuntimeError):
                control.validate_current(self.plan, value)

    def testRejectsMetadataFolderIdentityTrashAndConflictChanges(self):
        changes = {"name": "other.md", "parentId": "elsewhere", "metadata": {"title": "changed"},
            "assets": [{"path": "media/a.png"}], "state": "trashed", "id": "other", "revision": "3",
            "conflictIds": ["conflict"], "purgeAt": "tomorrow"}
        for key, value in changes.items():
            current = copy.deepcopy(self.snapshot); current[key] = value
            with self.subTest(field=key), self.assertRaises(RuntimeError):
                control.validate_current(self.plan, current)

    def testCommittedMarkerAndFinalSpaceNewlineAreRequiredAndPreserved(self):
        current = self.current(control.LOCAL_FINAL, committed=True)
        self.assertEqual(control.validate_current(self.plan, current, committed=True), control.LOCAL_FINAL)
        with self.assertRaises(RuntimeError):
            control.validate_current(self.plan, current)
        current["markdownSource"] = current["markdownSource"].replace(self.plan["remoteMarker"], "REMOTE-wrong")
        with self.assertRaises(RuntimeError):
            control.validate_current(self.plan, current, committed=True)

    def testFrozenWireRetainsBaseAndOnlyChangesRemote(self):
        wire = self.plan["wire"]
        self.assertEqual(wire["base"], {"source": "revision", "revision": 4})
        self.assertEqual(set(wire["desiredSnapshot"]), {"markdownSource"})
        self.assertEqual(wire["desiredSnapshot"]["markdownSource"].replace(self.plan["remoteMarker"], "base"), control.BASE)
        with tempfile.TemporaryDirectory(prefix="typing-control-unit-") as directory:
            path = Path(directory) / "prepared.json"
            control.persist(path, self.plan)
            control.persist(path.parent / "operation-request.json", wire)
            self.assertEqual(control.read_plan(path)["wire"], wire)
            control.persist(path.parent / "operation-request.json", wire)
            changed = copy.deepcopy(wire); changed["base"]["revision"] = 9
            with self.assertRaises(RuntimeError):
                control.persist(path.parent / "operation-request.json", changed)

    def testFreezeRejectsWrongFixtureOrUnexpectedTypingTarget(self):
        for text in [control.BASE.replace("base", "other", 1), control.BASE.rstrip("\n")]:
            value = copy.deepcopy(self.snapshot); value["markdownSource"] = text
            with self.assertRaises(RuntimeError):
                control.make_plan(value["id"], 4, value, control.LOCAL_FINAL)
        for target in ["replacement", "Local: base\n\nnew paragraph", "Local: base\r\n"]:
            with self.assertRaises(RuntimeError):
                control.make_plan(self.snapshot["id"], 4, self.snapshot, target)

    def testRepairFixtureRequiresExplicitNameAndKeepsOriginalPlanReadable(self):
        repair = copy.deepcopy(self.snapshot); repair["name"] = control.REPAIR_NAME
        with self.assertRaises(RuntimeError):
            control.make_plan(repair["id"], 4, repair, control.LOCAL_FINAL)
        plan = control.make_plan(repair["id"], 4, repair, control.LOCAL_FINAL, control.REPAIR_NAME)
        self.assertEqual(plan["expectedName"], control.REPAIR_NAME)
        with tempfile.TemporaryDirectory(prefix="typing-control-legacy-plan-") as directory:
            old = copy.deepcopy(self.plan); old.pop("expectedName")
            path = Path(directory) / "prepared.json"
            control.persist(path, old); control.persist(path.parent / "operation-request.json", old["wire"])
            self.assertEqual(control.read_plan(path)["baseSnapshot"]["name"], control.NAME)

    def testMacFixtureRequiresItsExplicitName(self):
        mac = copy.deepcopy(self.snapshot); mac["name"] = control.MAC_NAME
        with self.assertRaises(RuntimeError):
            control.make_plan(mac["id"], 4, mac, control.LOCAL_FINAL)
        plan = control.make_plan(mac["id"], 4, mac, control.LOCAL_FINAL, control.MAC_NAME)
        self.assertEqual(plan["expectedName"], control.MAC_NAME)


    def testRichFixturesRequireTheirExplicitNamesAndCannotReuseSourcePlan(self):
        for name in [control.RICH_IOS_NAME, control.RICH_MAC_NAME]:
            snapshot = copy.deepcopy(self.snapshot); snapshot["name"] = name
            with self.subTest(name=name):
                with self.assertRaises(RuntimeError):
                    control.make_plan(snapshot["id"], 4, snapshot, control.LOCAL_FINAL)
                plan = control.make_plan(snapshot["id"], 4, snapshot, control.LOCAL_FINAL, name)
                self.assertEqual(plan["expectedName"], name)
                with self.assertRaises(RuntimeError):
                    control.validate_current(self.plan, snapshot)


if __name__ == "__main__":
    unittest.main()
