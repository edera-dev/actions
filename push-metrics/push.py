import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import remote_write_pb2 as pb
import snappy

metrics = os.environ.get("METRICS", "")
metrics_file = os.environ.get("METRICS_FILE", "")
remote_write_url = os.environ["REMOTE_WRITE_URL"]
audience = os.environ["AUDIENCE"]
timestamp_ms_env = os.environ.get("TIMESTAMP_MS", "")

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
    with open(metrics_file) as f:
        metrics_text = f.read()
else:
    metrics_text = metrics

timestamp_ms = int(timestamp_ms_env) if timestamp_ms_env else int(time.time() * 1000)

LINE_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})?\s+(\S+)$')
LABEL_RE = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def unescape(value: str) -> str:
    return value.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def parse_exposition(text: str):
    samples = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        m = LINE_RE.match(line)
        if not m:
            print(f"::error::could not parse metric line: {line}", file=sys.stderr)
            sys.exit(1)
        name, _, labels_str, value = m.groups()
        labels = {"__name__": name}
        if labels_str:
            for lm in LABEL_RE.finditer(labels_str):
                key, val = lm.groups()
                labels[key] = unescape(val)
        samples.append((labels, float(value)))
    return samples


def build_write_request(samples, ts_ms):
    wr = pb.WriteRequest()
    for labels, value in samples:
        ts = wr.timeseries.add()
        for key, val in labels.items():
            label = ts.labels.add()
            label.name = key
            label.value = val
        sample = ts.samples.add()
        sample.value = value
        sample.timestamp = ts_ms
    return wr


def fetch_json(url: str, headers: dict) -> dict:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request) as response:
        return json.load(response)


samples = parse_exposition(metrics_text)
if not samples:
    print("::error::no metric samples found to push", file=sys.stderr)
    sys.exit(1)

write_request = build_write_request(samples, timestamp_ms)
compressed_body = snappy.compress(write_request.SerializeToString())

token_url = f"{id_token_request_url}&audience={urllib.parse.quote(audience)}"
token_response = fetch_json(
    token_url, {"Authorization": f"bearer {id_token_request_token}"}
)
oidc_token = token_response["value"]

request = urllib.request.Request(
    remote_write_url,
    data=compressed_body,
    method="POST",
    headers={
        "Authorization": f"Bearer {oidc_token}",
        "Content-Encoding": "snappy",
        "Content-Type": "application/x-protobuf",
        "X-Prometheus-Remote-Write-Version": "0.1.0",
    },
)
try:
    with urllib.request.urlopen(request) as response:
        print(f"pushed {len(samples)} sample(s) to {remote_write_url}: {response.status}")
except urllib.error.HTTPError as e:
    print(f"::error::push to {remote_write_url} failed: {e.status} {e.read().decode()}", file=sys.stderr)
    sys.exit(1)
