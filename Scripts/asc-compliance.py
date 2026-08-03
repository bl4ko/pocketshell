import base64
import json
import os
import sys
import time
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.bl4ko.pocketshell"
build_version = sys.argv[1]


def token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    path = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    with open(path, "rb") as fh:
        key = serialization.load_pem_private_key(fh.read(), password=None)

    def b64(raw):
        return base64.urlsafe_b64encode(raw).rstrip(b"=")

    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = b64(json.dumps(header).encode()) + b"." + b64(json.dumps(payload).encode())
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return (signing_input + b"." + b64(raw_sig)).decode()


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


apps = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
app_id = apps[0]["id"]

# The iOS and Catalyst uploads are two separate builds of the same version.
cleared = set()
for attempt in range(60):
    builds = call(
        "GET",
        f"/builds?filter[app]={app_id}&filter[version]={build_version}"
        "&fields[builds]=version,processingState,usesNonExemptEncryption",
    )["data"]
    for b in builds:
        if b["id"] in cleared or b["attributes"]["usesNonExemptEncryption"] is not None:
            cleared.add(b["id"])
            continue
        call(
            "PATCH",
            f"/builds/{b['id']}",
            {
                "data": {
                    "type": "builds",
                    "id": b["id"],
                    "attributes": {"usesNonExemptEncryption": False},
                }
            },
        )
        cleared.add(b["id"])
        print(f"export compliance cleared: build {build_version} ({b['id']})")
    if len(cleared) >= 2:
        sys.exit(0)
    time.sleep(20)

print(f"gave up waiting: {len(cleared)}/2 builds of {build_version} visible", file=sys.stderr)
sys.exit(1)
