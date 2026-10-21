"""Release fixed Dependabot CVEs using GitHub's alert-to-PR associations."""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
from pathlib import Path


ALERT_QUERY = """
query($owner:String!, $name:String!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    vulnerabilityAlerts(first:100, after:$cursor, states:[FIXED]) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number state fixedAt
        dependabotUpdate {
          pullRequest {
            number merged mergedAt baseRefName
            author { __typename login }
            mergeCommit { oid }
          }
        }
        securityAdvisory { identifiers { type value } }
      }
    }
  }
}
"""


class API:
    def __init__(self, repo):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid repository")
        self.repo = repo

    def request(self, endpoint, body=None, *, alert_token=False):
        command = ["gh", "api", "--hostname", "github.com", endpoint]
        env = os.environ.copy()
        if alert_token and env.get("DEPENDABOT_ALERTS_TOKEN"):
            env["GH_TOKEN"] = env["DEPENDABOT_ALERTS_TOKEN"]
        if body is not None:
            command += ["--method", "POST", "--input", "-"]
        try:
            result = subprocess.run(
                command, input=json.dumps(body) if body is not None else None,
                text=True, capture_output=True, env=env, check=True,
            )
        except subprocess.CalledProcessError as error:
            raise RuntimeError(
                f"GitHub API request failed for {endpoint}; check access and connectivity. "
                "No negative security classification can be inferred from this failure."
            ) from error
        value = json.loads(result.stdout)
        if isinstance(value, dict) and value.get("errors"):
            raise RuntimeError("GitHub returned GraphQL errors; classification is unknown")
        return value

    def get(self, path):
        return self.request(f"repos/{self.repo}/{path}")

    def post(self, path, body):
        return self.request(f"repos/{self.repo}/{path}", body)

    def alerts(self):
        owner, name = self.repo.split("/")
        cursor = None
        seen = set()
        while True:
            value = self.request("graphql", {
                "query": ALERT_QUERY,
                "variables": {"owner": owner, "name": name, "cursor": cursor},
            }, alert_token=True)
            connection = value["data"]["repository"]["vulnerabilityAlerts"]
            yield from connection["nodes"]
            page = connection["pageInfo"]
            if not page["hasNextPage"]:
                return
            cursor = page["endCursor"]
            if not cursor or cursor in seen:
                raise RuntimeError("Invalid alert pagination; classification is unknown")
            seen.add(cursor)

    def compare(self, base, head):
        return self.get(f"compare/{base}...{head}")["status"]


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def fixed_dependabot_cves(alert, branch):
    """Missing links are unconfirmed; stale links to previously fixed alerts don't count."""
    pr = (alert.get("dependabotUpdate") or {}).get("pullRequest")
    if alert["state"] != "FIXED" or not pr or not pr["merged"]:
        return None
    author = pr.get("author") or {}
    if (author.get("__typename") != "Bot"
            or author.get("login") not in {"dependabot", "dependabot[bot]"}
            or pr["baseRefName"] != branch):
        return None
    cves = sorted({identifier["value"]
                   for identifier in alert["securityAdvisory"]["identifiers"]
                   if identifier["type"] == "CVE"})
    if not cves or not alert.get("fixedAt") or not pr.get("mergedAt"):
        return None
    # Live replicator data links some alerts fixed years earlier to a newer PR.
    # Allow delayed alert updates, but reject alerts fixed BEFORE this PR merged.
    if timestamp(alert["fixedAt"]) < timestamp(pr["mergedAt"]):
        return None
    sha = (pr.get("mergeCommit") or {}).get("oid", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Confirmed security PR has no valid merge commit")
    return {"alert": alert["number"], "pr": pr["number"], "sha": sha, "cves": cves}


def evaluate(api):
    branch = api.request(f"repos/{api.repo}")["default_branch"]
    candidate = api.get(f"commits/{branch}")["sha"]
    latest = api.get("releases/latest")
    tag = latest["tag_name"]
    if latest["draft"] or latest["prerelease"] or not re.fullmatch(r"\d+\.\d+\.\d+", tag):
        raise ValueError("Expected a published stable X.Y.Z release")
    if not re.fullmatch(r"[0-9a-f]{40}", candidate):
        raise ValueError("Invalid candidate commit")
    major, minor, _ = map(int, tag.split("."))
    decision = {"release": False, "reason": "No unreleased, confirmed Dependabot CVE fixes",
                "branch": branch, "sha": candidate, "baseline": tag,
                "tag": f"{major}.{minor + 1}.0", "fixes": []}
    # Fully collect every page before making a decision or any mutation.
    fixes = [fix for alert in api.alerts()
             if (fix := fixed_dependabot_cves(alert, branch))]
    comparisons = {}
    for fix in fixes:
        sha = fix["sha"]
        if sha not in comparisons:
            comparisons[sha] = api.compare(tag, sha)
        status = comparisons[sha]
        if status in {"behind", "identical"}:
            continue  # Already in the latest release; don't backfill old fixes.
        if status != "ahead":
            raise RuntimeError("Security PR diverges from release history")
        if api.compare(sha, candidate) not in {"ahead", "identical"}:
            raise RuntimeError("Security fix is not an ancestor of the candidate")
        decision["fixes"].append(fix)
    if not decision["fixes"]:
        return decision
    runs = api.get(f"actions/workflows/ci.yml/runs?head_sha={candidate}&event=push&per_page=100")
    matching = [run for run in runs["workflow_runs"]
                if run["head_sha"] == candidate and run["head_branch"] == branch
                and run["event"] == "push"]
    # A later rerun supersedes an earlier success; never release while it is running.
    if not matching or max(matching, key=lambda r: (r["id"], r["run_attempt"]))["conclusion"] != "success":
        decision["reason"] = "Waiting for successful ci.yml on the current default-branch commit"
        return decision
    decision.update(release=True, reason="Confirmed Dependabot CVEs fixed; default-branch CI passed")
    return decision


def publish(api, decision):
    if not decision["release"]:
        return
    # Re-read mutable refs under workflow concurrency before creating anything.
    if api.get(f"commits/{decision['branch']}")["sha"] != decision["sha"]:
        raise RuntimeError("Default branch advanced; wait for its CI and a fresh evaluation")
    if api.get("releases/latest")["tag_name"] != decision["baseline"]:
        raise RuntimeError("Latest release changed; re-evaluate")
    # GitHub's create-ref API refuses overwrites. Existing/pending tags require investigation.
    api.post("git/refs", {"ref": f"refs/tags/{decision['tag']}", "sha": decision["sha"]})
    # GITHUB_TOKEN-created tags don't trigger push workflows. Dispatch explicitly ON THE TAG.
    # Never retry this POST: a lost response may already have started a release.
    try:
        response = api.post("actions/workflows/ci.yml/dispatches", {
            "ref": decision["tag"], "return_run_details": True,
        })
        run_id = response["workflow_run_id"]
        if type(run_id) is not int or run_id <= 0:
            raise ValueError("Invalid dispatch run ID")
        run = api.get(f"actions/runs/{run_id}")
        if (run["event"] != "workflow_dispatch" or run["head_sha"] != decision["sha"]
                or run["head_branch"] != decision["tag"]):
            raise ValueError("Dispatched run does not match release tag and commit")
    except Exception as error:
        raise RuntimeError(
            f"Tag {decision['tag']} exists. Inspect Actions before any manual re-dispatch; "
            "the release may already be running. Never move or delete the tag."
        ) from error
    decision["run_url"] = f"https://github.com/{api.repo}/actions/runs/{run_id}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"), required=False)
    parser.add_argument("--mode", choices=["report", "auto"], default="report")
    args = parser.parse_args()
    api = API(args.repo or "")
    decision = evaluate(api)
    if args.mode == "auto":
        publish(api, decision)
    output = json.dumps({"mode": args.mode, **decision}, indent=2)
    print(output)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
            summary.write(f"## Dependabot CVE release decision\n\n```json\n{output}\n```\n")


if __name__ == "__main__":
    main()
