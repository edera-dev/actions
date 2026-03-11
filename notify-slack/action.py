import os
import re
import json
import subprocess

repo = os.environ["GITHUB_REPOSITORY"]
run_id = os.environ["GITHUB_RUN_ID"]
workflow = os.environ["GITHUB_WORKFLOW"]


def run_gh(*args):
    result = subprocess.run(
        ["gh", "api", *args], capture_output=True, text=True, check=True
    )
    return result.stdout


snippet_lines = []

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

        # Find last error line
        error_idx = len(lines) - 1
        for i in reversed(range(len(lines))):
            if "error" in lines[i].lower():
                error_idx = i
                break

        start = max(0, error_idx - 2)
        end = min(len(lines), error_idx + 3)
        snippet_lines = [
            ">```",
            *lines[start:end],
            "```",
        ]

except subprocess.CalledProcessError:
    snippet_lines = []

run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
slack_msg = [
    f"*{workflow} Workflow `Failed`*",
    f"> *Repo:* {repo}",
    f"> *Run:* <{run_url}|{run_id}>",
    *snippet_lines,
]
slack_msg = "\\n".join(slack_msg)
print(f"{slack_msg}")

# Write multiline output to GITHUB_OUTPUT
with open(os.environ["GITHUB_OUTPUT"], "a") as f:
    f.write(f"slack_msg<<EOF\n{slack_msg}\nEOF\n")
