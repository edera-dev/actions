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
azure_remote_write_url = os.environ["AZURE_REMOTE_WRITE_URL"]
azure_tenant_id = os.environ["AZURE_TENANT_ID"]
azure_client_id = os.environ["AZURE_CLIENT_ID"]
legacy_remote_write_url = os.environ.get("LEGACY_REMOTE_WRITE_URL", "")
legacy_audience = os.environ.get("LEGACY_AUDIENCE", "")
timestamp_ms_env = os.environ.get("TIMESTAMP_MS", "")

AZURE_TOKEN_EXCHANGE_AUDIENCE = "api://AzureADTokenExchange"
AZURE_MONITOR_SCOPE = "https://monitor.azure.com/.default"
MAX_ATTEMPTS = 5
RETRYABLE_STATUSES = {408, 429, 500, 502, 503, 504}

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


def with_retries(description: str, fn):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return fn()
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if e.code not in RETRYABLE_STATUSES or attempt == MAX_ATTEMPTS:
                raise RuntimeError(f"{description} failed: {e.code} {body}") from e
            print(f"{description} attempt {attempt} failed: {e.code} {body}", file=sys.stderr)
        except urllib.error.URLError as e:
            if attempt == MAX_ATTEMPTS:
                raise RuntimeError(f"{description} failed: {e.reason}") from e
            print(f"{description} attempt {attempt} failed: {e.reason}", file=sys.stderr)
        time.sleep(2 ** attempt)


def fetch_json(request: urllib.request.Request) -> dict:
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def github_oidc_token(audience: str) -> str:
    token_url = f"{id_token_request_url}&audience={urllib.parse.quote(audience)}"
    request = urllib.request.Request(
        token_url, headers={"Authorization": f"bearer {id_token_request_token}"}
    )
    return with_retries("GitHub OIDC token request", lambda: fetch_json(request))["value"]


def azure_monitor_token() -> str:
    body = urllib.parse.urlencode(
        {
            "client_id": azure_client_id,
            "grant_type": "client_credentials",
            "scope": AZURE_MONITOR_SCOPE,
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": github_oidc_token(AZURE_TOKEN_EXCHANGE_AUDIENCE),
        }
    ).encode()
    request = urllib.request.Request(
        f"https://login.microsoftonline.com/{azure_tenant_id}/oauth2/v2.0/token",
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return with_retries("Azure token exchange", lambda: fetch_json(request))["access_token"]


def push(url: str, bearer_token: str) -> int:
    request = urllib.request.Request(
        url,
        data=compressed_body,
        method="POST",
        headers={
            "Authorization": f"Bearer {bearer_token}",
            "Content-Encoding": "snappy",
            "Content-Type": "application/x-protobuf",
            "X-Prometheus-Remote-Write-Version": "0.1.0",
        },
    )

    def send():
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status

    return with_retries(f"push to {url}", send)


samples = parse_exposition(metrics_text)
if not samples:
    print("::error::no metric samples found to push", file=sys.stderr)
    sys.exit(1)

write_request = build_write_request(samples, timestamp_ms)
compressed_body = snappy.compress(write_request.SerializeToString())

failed = False

try:
    status = push(azure_remote_write_url, azure_monitor_token())
    print(f"pushed {len(samples)} sample(s) to Azure Monitor: {status}")
except RuntimeError as e:
    print(f"::error::{e}", file=sys.stderr)
    failed = True

if legacy_remote_write_url:
    try:
        status = push(legacy_remote_write_url, github_oidc_token(legacy_audience))
        print(f"pushed {len(samples)} sample(s) to {legacy_remote_write_url}: {status}")
    except RuntimeError as e:
        print(f"::warning::{e}", file=sys.stderr)

sys.exit(1 if failed else 0)
