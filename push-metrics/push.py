import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

metrics = os.environ.get("METRICS", "")
metrics_file = os.environ.get("METRICS_FILE", "")
job = os.environ["JOB"]
grouping_labels = os.environ.get("GROUPING_LABELS", "")
pushgateway_url = os.environ["PUSHGATEWAY_URL"]
audience = os.environ["AUDIENCE"]

id_token_request_token = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
id_token_request_url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")

if not id_token_request_token or not id_token_request_url:
    print(
        "::error::No OIDC token available. Set `permissions: id-token: write` "
        "on the calling job.",
        file=sys.stderr,
    )
    sys.exit(1)

if bool(metrics) == bool(metrics_file):
    print(
        "::error::Exactly one of `metrics` or `metrics-file` must be set.",
        file=sys.stderr,
    )
    sys.exit(1)

if metrics_file:
    with open(metrics_file, "rb") as f:
        body = f.read()
else:
    body = metrics.encode()
    if not body.endswith(b"\n"):
        body += b"\n"


def fetch_json(url: str, headers: dict) -> dict:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request) as response:
        return json.load(response)


token_url = f"{id_token_request_url}&audience={urllib.parse.quote(audience)}"
token_response = fetch_json(
    token_url, {"Authorization": f"bearer {id_token_request_token}"}
)
oidc_token = token_response["value"]

push_url = f"{pushgateway_url}/metrics/job/{urllib.parse.quote(job)}"
for pair in filter(None, grouping_labels.split(",")):
    key, _, value = pair.partition("=")
    push_url += f"/{urllib.parse.quote(key)}/{urllib.parse.quote(value)}"

request = urllib.request.Request(
    push_url,
    data=body,
    method="POST",
    headers={"Authorization": f"Bearer {oidc_token}"},
)
try:
    with urllib.request.urlopen(request) as response:
        print(f"pushed to {push_url}: {response.status}")
except urllib.error.HTTPError as e:
    print(f"::error::push to {push_url} failed: {e.status} {e.read().decode()}", file=sys.stderr)
    sys.exit(1)
