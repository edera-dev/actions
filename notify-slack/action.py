import os
import re
import json
import subprocess

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


error_lines = []

try:
    # Find the failing job
    jobs = json.loads(run_gh(f"repos/{repo}/actions/runs/{run_id}/jobs"))
    failing_job = None
    for job in jobs["jobs"]:
        if job["conclusion"] in (None, "failure"):
            failing_job = job
            break

    if failing_job:
        # Download log and strip ANSI codes
        raw_log = run_gh(f"repos/{repo}/actions/jobs/{failing_job['id']}/logs")
        log = re.sub(r"\x1B\[[0-9;]*m", "", raw_log)
        lines = log.splitlines()

        # Prefer the runner's own error annotations.
        # Keyed by message so a retried step only reports once.
        annotated = {}
        for line in lines:
            marker = line.find("##[error]")
            if marker != -1:
                annotated[line[marker:]] = line

        if annotated:
            error_lines = list(annotated.values())[-3:]
        else:
            # Find last error line
            error_idx = len(lines) - 1
            for i in reversed(range(len(lines))):
                if "error" in lines[i].lower():
                    error_idx = i
                    break

            start = max(0, error_idx - 2)
            end = min(len(lines), error_idx + 3)
            error_lines = lines[start:end]

except subprocess.CalledProcessError:
    error_lines = []

# Was this branch already failing before the current run started? If so the
# breakage predates the head commit, so its author is not on the hook for it.
already_failing = False
previous = None
workflow_id = None
try:
    run = json.loads(run_gh(f"repos/{repo}/actions/runs/{run_id}"))
    workflow_id = run["workflow_id"]
    # Newest first, so the newest completed run started before this one is the
    # predecessor. %3C is the '<' of the created range filter.
    completed = json.loads(
        run_gh(
            f"repos/{repo}/actions/workflows/{workflow_id}/runs"
            f"?branch={branch}&status=completed&per_page=1"
            f"&created=%3C{run['created_at']}"
        )
    )["workflow_runs"]
    previous = completed[0] if completed else None
    already_failing = bool(previous) and previous["conclusion"] == "failure"
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
            author = prs[0]["user"]["login"]
            pr = prs[0]["number"]
        else:
            commit = json.loads(run_gh(f"repos/{repo}/commits/{head_sha}"))
            author = (commit.get("author") or {}).get("login")
    except (subprocess.CalledProcessError, KeyError, ValueError):
        pass

run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
pr_ref = f" (PR <https://github.com/{repo}/pull/{pr}|#{pr}>)" if pr else ""

blame_lines = []
if author:
    blame_lines.append(f"> *Author of head commit:* `@{author}`{pr_ref}")
if already_failing:
    prev_url = f"https://github.com/{repo}/actions/runs/{previous['id']}"
    blame_lines.append(
        f"> :warning: the previous run <{prev_url}|#{previous['run_number']}> "
        f"on `{branch}` also failed, so this may be pre-existing"
    )

# One tracking issue per (workflow, branch) breakage. Further failing runs comment
# on the already-open issue instead of filing another. Closing the issue while the
# branch is still broken will result in a fresh issue.
issue_lines = []
if create_issue:
    try:
        marker = f"<!-- ci-failure:{workflow_id}:{branch} -->"
        snippet = "\n".join(["```", *error_lines, "```"]) if error_lines else ""

        existing = None
        for issue in json.loads(
            run_gh(f"repos/{repo}/issues?state=open&labels={issue_label}&per_page=100")
        ):
            if marker in (issue.get("body") or ""):
                existing = issue
                break

        if existing:
            run_gh(
                f"repos/{repo}/issues/{existing['number']}/comments",
                payload={
                    "body": f"Still failing: {run_url} (`{event_name}` of "
                    f"`{head_sha[:12]}`)\n\n{snippet}"
                },
            )
            issue_lines.append(
                f"> *Tracking issue:* <{existing['html_url']}|#{existing['number']}> "
                "(updated)"
            )
        else:
            # Assign the author only when this run is the one that turned the branch
            # red, and the author is not a bot (digestabot, etc).
            assignees = []
            if author and not author.endswith("[bot]") and not already_failing:
                assignees = [author]

            body = [marker, f"Automated report from `{workflow}`.", ""]
            body.append(f"- **Branch:** `{branch}`")
            body.append(f"- **Failing run:** {run_url}")
            body.append(f"- **Head commit:** {head_sha}")
            if pr:
                body.append(f"- **PR:** #{pr} (author @{author})")
            elif author:
                body.append(f"- **Commit author:** @{author}")
            if already_failing:
                body.append(
                    f"- **Note:** run #{previous['run_number']} already failed before "
                    "this commit landed, so the cause may be older than it"
                )
            if snippet:
                body += ["", snippet]

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
                owner = f", assigned to `@{assigned[0]}`"
            elif assignees:
                # GitHub drops assignees that lack write access rather than erroring.
                owner = f", could not assign `@{assignees[0]}`"
            else:
                owner = ", unassigned"
            issue_lines.append(
                f"> *Tracking issue:* <{issue['html_url']}|#{issue['number']}>{owner}"
            )
    except (subprocess.CalledProcessError, KeyError, ValueError):
        issue_lines = []

slack_msg = [
    f"*{workflow} Workflow `Failed`*",
    f"> *Repo:* {repo}",
    f"> *Run:* <{run_url}|{run_id}>",
    *blame_lines,
    *issue_lines,
]
if error_lines:
    slack_msg += [">```", *error_lines, "```"]

# The message is interpolated into a YAML double-quoted scalar in action.yml, so
# quotes and backslashes carried in from log lines have to survive that parse. The
# joining "\n" is added after escaping: YAML turns it into the newline Slack renders.
slack_msg = "\\n".join(
    line.replace("\\", "\\\\").replace('"', '\\"') for line in slack_msg
)
print(f"{slack_msg}")

# Write multiline output to GITHUB_OUTPUT
with open(os.environ["GITHUB_OUTPUT"], "a") as f:
    f.write(f"slack_msg<<EOF\n{slack_msg}\nEOF\n")
