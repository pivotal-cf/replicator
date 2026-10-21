import copy
import json
import subprocess
import unittest
from unittest.mock import patch

import release


MERGE = "a" * 40
HEAD = "b" * 40
ALERT = {
    "number": 19, "state": "FIXED", "fixedAt": "2025-06-11T23:55:39Z",
    "dependabotUpdate": {"pullRequest": {
        "number": 16, "merged": True, "mergedAt": "2025-06-11T23:55:37Z",
        "baseRefName": "master", "author": {"__typename": "Bot", "login": "dependabot"},
        "mergeCommit": {"oid": MERGE},
    }},
    "securityAdvisory": {"identifiers": [{"type": "CVE", "value": "CVE-2025-22870"}]},
}


class FakeAPI:
    repo = "pivotal-cf/replicator"

    def __init__(self):
        self.alert_list = [copy.deepcopy(ALERT)]
        self.candidate = HEAD
        self.baseline = "0.24.0"
        self.posts = []
        self.runs = [{"id": 10, "run_attempt": 1, "head_sha": HEAD,
                      "head_branch": "master", "event": "push", "conclusion": "success"}]
        self.comparisons = {("0.24.0", MERGE): "ahead", (MERGE, HEAD): "ahead"}
        self.dispatch_error = False

    def request(self, path):
        assert path == "repos/pivotal-cf/replicator"
        return {"default_branch": "master"}

    def get(self, path):
        if path == "commits/master":
            return {"sha": self.candidate}
        if path == "releases/latest":
            return {"tag_name": self.baseline, "draft": False, "prerelease": False}
        if path.startswith("actions/workflows/ci.yml/runs?"):
            return {"workflow_runs": self.runs}
        if path == "actions/runs/42":
            return {"event": "workflow_dispatch", "head_sha": HEAD, "head_branch": "0.25.0"}
        raise AssertionError(path)

    def alerts(self):
        yield from self.alert_list

    def compare(self, base, head):
        return self.comparisons[base, head]

    def post(self, path, body):
        self.posts.append((path, body))
        if path.endswith("dispatches"):
            if self.dispatch_error:
                raise RuntimeError("Lost response")
            return {"workflow_run_id": 42}
        return {}


class ClassificationTests(unittest.TestCase):
    def test_security_fix_qualifies(self):
        self.assertEqual(release.fixed_dependabot_cves(ALERT, "master")["cves"],
                         ["CVE-2025-22870"])

    def test_routine_pr_has_no_associated_alert(self):
        api = FakeAPI()
        api.alert_list = []
        self.assertFalse(release.evaluate(api)["release"])
        self.assertEqual(api.posts, [])

    def test_dismissed_open_and_missing_associations_do_not_qualify(self):
        for state in ["OPEN", "DISMISSED", "AUTO_DISMISSED"]:
            alert = {**ALERT, "state": state}
            self.assertIsNone(release.fixed_dependabot_cves(alert, "master"))
        self.assertIsNone(release.fixed_dependabot_cves(
            {**ALERT, "dependabotUpdate": None}, "master"))

    def test_stale_link_does_not_claim_old_cve_was_fixed_by_new_pr(self):
        alert = {**ALERT, "fixedAt": "2023-11-15T21:13:26Z"}
        self.assertIsNone(release.fixed_dependabot_cves(alert, "master"))

    def test_delayed_fixed_state_is_accepted(self):
        alert = {**ALERT, "fixedAt": "2025-06-16T23:55:39Z"}
        self.assertIsNotNone(release.fixed_dependabot_cves(alert, "master"))

    def test_human_unmerged_other_branch_and_no_cve_do_not_qualify(self):
        for field, value in [("author", {"__typename": "User", "login": "maintainer"}),
                             ("merged", False), ("baseRefName", "release")]:
            alert = copy.deepcopy(ALERT)
            alert["dependabotUpdate"]["pullRequest"][field] = value
            self.assertIsNone(release.fixed_dependabot_cves(alert, "master"))
        alert = {**ALERT, "securityAdvisory": {"identifiers": [{"type": "GHSA", "value": "GHSA-id"}]}}
        self.assertIsNone(release.fixed_dependabot_cves(alert, "master"))


class DecisionTests(unittest.TestCase):
    def test_eligible_fix_gets_next_minor_tag_without_mutation(self):
        api = FakeAPI()
        decision = release.evaluate(api)
        self.assertTrue(decision["release"])
        self.assertEqual(decision["tag"], "0.25.0")
        self.assertEqual(api.posts, [])

    def test_already_released_fix_does_not_release_again(self):
        for status in ["behind", "identical"]:
            api = FakeAPI()
            api.comparisons["0.24.0", MERGE] = status
            self.assertFalse(release.evaluate(api)["release"])

    def test_ci_must_pass_on_exact_candidate_and_branch(self):
        for change in [{"conclusion": "failure"}, {"conclusion": None},
                       {"head_sha": MERGE}, {"head_branch": "other"}, {"event": "pull_request"}]:
            api = FakeAPI()
            api.runs[0].update(change)
            self.assertFalse(release.evaluate(api)["release"])

    def test_newer_failed_run_supersedes_old_success(self):
        api = FakeAPI()
        api.runs.append({**api.runs[0], "id": 11, "conclusion": "failure"})
        self.assertFalse(release.evaluate(api)["release"])

    def test_diverged_history_and_missing_fix_fail(self):
        for pair in [("0.24.0", MERGE), (MERGE, HEAD)]:
            api = FakeAPI()
            api.comparisons[pair] = "diverged"
            with self.assertRaises(RuntimeError):
                release.evaluate(api)
            self.assertEqual(api.posts, [])

    def test_later_page_error_never_produces_partial_decision(self):
        api = FakeAPI()
        def broken_alerts():
            yield copy.deepcopy(ALERT)
            raise RuntimeError("Page two forbidden")
        api.alerts = broken_alerts
        with self.assertRaises(RuntimeError):
            release.evaluate(api)
        self.assertEqual(api.posts, [])

    def test_nonstandard_release_fails_before_writes(self):
        api = FakeAPI()
        api.baseline = "0.25.0-rc.1"
        with self.assertRaises(ValueError):
            release.evaluate(api)


class PublishTests(unittest.TestCase):
    def test_tag_and_dispatch_on_tag(self):
        api = FakeAPI()
        decision = release.evaluate(api)
        release.publish(api, decision)
        self.assertEqual(api.posts, [
            ("git/refs", {"ref": "refs/tags/0.25.0", "sha": HEAD}),
            ("actions/workflows/ci.yml/dispatches", {"ref": "0.25.0", "return_run_details": True}),
        ])
        self.assertTrue(decision["run_url"].endswith("/42"))

    def test_changed_head_or_latest_release_blocks_tag(self):
        for field, value in [("candidate", MERGE), ("baseline", "0.25.0")]:
            api = FakeAPI()
            decision = release.evaluate(api)
            setattr(api, field, value)
            with self.assertRaises(RuntimeError):
                release.publish(api, decision)
            self.assertEqual(api.posts, [])

    def test_existing_tag_blocks_dispatch(self):
        api = FakeAPI()
        decision = release.evaluate(api)
        def existing_tag(path, body):
            self.assertEqual(path, "git/refs")
            raise RuntimeError("Reference already exists")
        api.post = existing_tag
        with self.assertRaises(RuntimeError):
            release.publish(api, decision)

    def test_lost_dispatch_response_is_not_retried(self):
        api = FakeAPI()
        api.dispatch_error = True
        with self.assertRaisesRegex(RuntimeError, "Inspect Actions"):
            release.publish(api, release.evaluate(api))
        self.assertEqual(len(api.posts), 2)

    def test_mismatched_dispatched_run_is_not_retried(self):
        api = FakeAPI()
        original_get = api.get
        api.get = lambda path: ({"event": "workflow_dispatch", "head_sha": MERGE,
                                 "head_branch": "0.25.0"}
                                if path == "actions/runs/42" else original_get(path))
        with self.assertRaisesRegex(RuntimeError, "Inspect Actions"):
            release.publish(api, release.evaluate(api))
        self.assertEqual(len(api.posts), 2)


class APITests(unittest.TestCase):
    def test_graphql_errors_fail(self):
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps({"errors": [{"message": "Forbidden"}]}))
        with patch("subprocess.run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "unknown"):
                release.API("pivotal-cf/replicator").request("graphql", {})

    def test_pagination_collects_all_pages(self):
        api = release.API("pivotal-cf/replicator")
        def page(nodes, more, cursor):
            return {"data": {"repository": {"vulnerabilityAlerts": {
                "nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": cursor},
            }}}}
        with patch.object(api, "request", side_effect=[page([ALERT], True, "next"), page([], False, None)]) as request:
            self.assertEqual(list(api.alerts()), [ALERT])
            self.assertEqual(request.call_args_list[1].args[1]["variables"]["cursor"], "next")


if __name__ == "__main__":
    unittest.main()
