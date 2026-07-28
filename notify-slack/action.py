import os
import json
import subprocess
import urllib.parse

repo = os.environ["GITHUB_REPOSITORY"]
run_id = os.environ["GITHUB_RUN_ID"]
workflow = os.environ["GITHUB_WORKFLOW"]
event_name = os.environ.get("GITHUB_EVENT_NAME", "")
head_sha = os.environ.get("GITHUB_SHA", "")
branch = os.environ.get("GITHUB_REF_NAME", "")
create_issue = os.environ.get("CREATE_ISSUE", "").lower() == "true"
issue_label = os.environ.get("ISSUE_LABEL", "ci")


def run_gh(*args, payload=None):
    result = subprocess.run(
        ["gh", "api", *args, *(["--input", "-"] if payload is not None else [])],
        input=json.dumps(payload) if payload is not None else None,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


# Link the failing job rather than quoting the logs in the issue, simpler and less clutter.
# If that is a problem later we can revisit
job_ref = ""
job_label = "Failing job"
try:
    jobs = [
        json.loads(line)
        for line in run_gh(
            f"repos/{repo}/actions/runs/{run_id}/jobs",
            "--paginate",
            "--jq",
            ".jobs[] | {name, conclusion, html_url}",
        ).splitlines()
        if line.strip()
    ]
    failing = [job for job in jobs if job["conclusion"] == "failure"]
    if not failing:
        # Called as a step inside the failing job itself, which has no conclusion
        # while it is still running. A sibling job that merely has not finished
        # yet must not win over a job that actually failed, hence the two passes.
        failing = [job for job in jobs if job["conclusion"] is None][:1]

    job_ref = ", ".join(f"[{j['name']}]({j['html_url']})" for j in failing)
    job_label = "Failing jobs" if len(failing) > 1 else "Failing job"
except (subprocess.CalledProcessError, KeyError, ValueError):
    job_ref = ""

# Was this branch already failing before the current run started? If so the
# breakage predates the head commit, so its author is not on the hook for it.
already_failing = False
pending = None
previous = None
workflow_id = None
try:
    run = json.loads(run_gh(f"repos/{repo}/actions/runs/{run_id}"))
    workflow_id = run["workflow_id"]
    # Newest first. %3C is the '<' of the created range filter.
    earlier = json.loads(
        run_gh(
            f"repos/{repo}/actions/workflows/{workflow_id}/runs"
            f"?branch={branch}&per_page=5"
            f"&created=%3C{run['created_at']}"
        )
    )["workflow_runs"]
    # Cancelled and skipped runs say nothing about the state of the branch, so the
    # predecessor is the newest run that actually reached a verdict.
    previous = next(
        (r for r in earlier if r["conclusion"] in ("success", "failure")), None
    )
    already_failing = bool(previous) and previous["conclusion"] == "failure"
    # Runs overlap: a run that started earlier and has not landed yet may be about
    # to fail for the same reason, which would make this commit not the culprit.
    pending = next((r for r in earlier if r["status"] != "completed"), None)
except (subprocess.CalledProcessError, KeyError, ValueError):
    pass

# Determine author of the PR that caused this breakage on the target branch. Only meaningful for `push`.
# The PR the head commit came from is the PR under suspicion. Scheduled and
# manual runs re-test a commit that landed some time earlier, so those are skipped/ignored.
author = None
pr = None
if event_name == "push":
    try:
        prs = json.loads(run_gh(f"repos/{repo}/commits/{head_sha}/pulls"))
        if prs:
            # A commit can belong to several PRs. The one whose merge produced it is
            # the one that put it on this branch.
            match = next(
                (p for p in prs if p.get("merge_commit_sha") == head_sha), prs[0]
            )
            author = match["user"]["login"]
            pr = match["number"]
        else:
            commit = json.loads(run_gh(f"repos/{repo}/commits/{head_sha}"))
            author = (commit.get("author") or {}).get("login")
    except (subprocess.CalledProcessError, KeyError, ValueError):
        pass

run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
pr_ref = f" (PR <https://github.com/{repo}/pull/{pr}|#{pr}>)" if pr else ""

# Slack carries blame only, rest goes in the issue.
blame_lines = []
if author:
    blame_lines.append(f"> *Author of head commit:* `@{author}`{pr_ref}")

# One tracking issue per (workflow, branch) breakage. Further failing runs comment
# on the already-open issue instead of filing another. Closing the issue while the
# branch is still broken will result in a fresh issue.
issue_lines = []
if create_issue:
    try:
        if not workflow_id:
            raise ValueError("run metadata unavailable")
        marker = f"<!-- ci-failure:{workflow_id}:{branch} -->"
        label_q = urllib.parse.quote(issue_label)
        existing = None
        for issue in json.loads(
            run_gh(f"repos/{repo}/issues?state=open&labels={label_q}&per_page=100")
        ):
            if marker in (issue.get("body") or ""):
                existing = issue
                break

        if existing:
            run_gh(
                f"repos/{repo}/issues/{existing['number']}/comments",
                payload={
                    "body": f"Still failing: {run_url} (`{event_name}` of "
                    f"`{head_sha[:12]}`)"
                    + (f"\n{job_label}: {job_ref}" if job_ref else "")
                },
            )
            owner = [a["login"] for a in existing.get("assignees") or []]
            who = f"`@{owner[0]}`" if owner else "nobody"
            issue_lines.append(
                f"> *Assigned to:* {who} - still failing, tracking issue "
                f"<{existing['html_url']}|#{existing['number']}>"
            )
        else:
            # Assign the author only when this run is the one that turned the branch
            # red, and the author is not a bot (digestabot, etc).
            assignees = []
            if (
                author
                and not author.endswith("[bot]")
                and not already_failing
                and not pending
            ):
                assignees = [author]

            body = [marker, f"Automated report from `{workflow}`.", ""]
            body.append(f"- **Branch:** `{branch}`")
            body.append(f"- **Failing run:** {run_url}")
            if job_ref:
                body.append(f"- **{job_label}:** {job_ref}")
            body.append(f"- **Head commit:** {head_sha}")
            if pr:
                body.append(f"- **PR:** #{pr} (author @{author})")
            elif author:
                body.append(f"- **Commit author:** @{author}")
            if already_failing:
                prev_url = f"https://github.com/{repo}/actions/runs/{previous['id']}"
                body.append(
                    f"- **Note:** run [#{previous['run_number']}]({prev_url}) already "
                    "failed before this commit landed, so the cause may be older "
                    "than it"
                )
            elif pending:
                pending_url = f"https://github.com/{repo}/actions/runs/{pending['id']}"
                body.append(
                    f"- **Note:** an earlier run [#{pending['run_number']}]"
                    f"({pending_url}) of this workflow was still in flight, so the "
                    "cause may predate this commit"
                )
            # An absent label would silently break dedup on the next failure.
            try:
                run_gh(
                    f"repos/{repo}/labels",
                    payload={"name": issue_label, "color": "c5def5"},
                )
            except subprocess.CalledProcessError:
                pass

            issue = json.loads(
                run_gh(
                    f"repos/{repo}/issues",
                    payload={
                        "title": f"CI failure: {workflow} on {branch}",
                        "body": "\n".join(body),
                        "labels": [issue_label],
                        "assignees": assignees,
                    },
                )
            )
            assigned = [a["login"] for a in issue.get("assignees") or []]
            if assigned:
                who = f"`@{assigned[0]}`"
            elif assignees:
                # GitHub drops assignees that lack write access rather than erroring.
                who = f"nobody, could not assign `@{assignees[0]}`"
            else:
                who = "nobody"
            issue_lines.append(
                f"> *Assigned to:* {who} - tracking issue "
                f"<{issue['html_url']}|#{issue['number']}>"
            )
    except (subprocess.CalledProcessError, KeyError, ValueError):
        # Say so rather than posting a message that looks like nothing was tracked.
        issue_lines = []
        blame_lines.append("> :warning: could not file a tracking issue")

slack_msg = [
    f"*{workflow} Workflow `Failed`*",
    f"> *Repo:* {repo} - run <{run_url}|{run_id}> on `{branch}`",
    # An issue names its assignee, so the author line is only worth printing when
    # no issue was filed.
    *(issue_lines or blame_lines),
]

# The message is interpolated into a YAML double-quoted scalar in action.yml, so
# quotes and backslashes have to survive that parse. The joining "\n" is added
# after escaping: YAML turns it into the newline Slack renders.
slack_msg = "\\n".join(
    line.replace("\\", "\\\\").replace('"', '\\"') for line in slack_msg
)
print(f"{slack_msg}")

# Write multiline output to GITHUB_OUTPUT
with open(os.environ["GITHUB_OUTPUT"], "a") as f:
    f.write(f"slack_msg<<EOF\n{slack_msg}\nEOF\n")
