#!/usr/bin/env python3
"""Keep the release pipeline from accumulating "Apple Development" certificates.

Why: every release run starts on a fresh macOS runner. `xcodebuild archive -allowProvisioningUpdates`
with an App Store Connect API key creates a new Apple Development certificate whose private key only
ever exists on that runner. After a few dozen runs the team hits Apple's certificate limit and archive
fails with "Your account has reached the maximum number of certificates".

This script talks to the App Store Connect API (stdlib + the `openssl` CLI for the ES256 JWT; no
third-party packages) and only ever touches DEVELOPMENT certificates:

  snapshot <file>          write the ids of the current development certificates to <file>
  revoke-stale             revoke development certificates created by an API key
                           (name/displayName contains "Created via API"), i.e. leftovers of earlier CI runs
  revoke-new <file>        revoke development certificates that are not in the snapshot <file>
                           (the ones this run created)

Add --dry-run to print what would be revoked without revoking. Distribution certificates are never
touched: the type allowlist below is the only thing that can be revoked.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8 written by write-key.sh).
Never prints key material or tokens.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
# The ONLY certificate types this script may revoke. Distribution types are deliberately absent.
REVOCABLE_TYPES = frozenset({"DEVELOPMENT", "IOS_DEVELOPMENT"})
API_CREATED_MARKER = "created via api"


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_ecdsa(der: bytes, size: int = 32) -> bytes:
    """Convert an ASN.1 DER ECDSA signature (openssl output) to the raw r||s form JWS ES256 needs."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER sequence")
    idx = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[idx] != 0x02:
            raise ValueError("expected DER integer")
        length = der[idx + 1]
        value = der[idx + 2: idx + 2 + length].lstrip(b"\x00")
        if len(value) > size:
            raise ValueError("integer too long")
        out += value.rjust(size, b"\x00")
        idx += 2 + length
    return out


def make_jwt(key_id: str, issuer_id: str, key_path: str, now: int | None = None) -> str:
    now = int(time.time()) if now is None else now
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}." \
                    f"{_b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{_b64url(der_to_raw_ecdsa(der))}"


class Client:
    def __init__(self, token: str):
        self.token = token

    def request(self, method: str, url: str):
        req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {self.token}"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            return json.loads(body) if body else None

    def list_certificates(self) -> list[dict]:
        certs, url = [], f"{API}/certificates?limit=200"
        while url:
            page = self.request("GET", url)
            certs.extend(page.get("data", []))
            url = (page.get("links") or {}).get("next")
        return certs

    def revoke(self, cert_id: str) -> None:
        self.request("DELETE", f"{API}/certificates/{cert_id}")


def is_development(cert: dict) -> bool:
    return (cert.get("attributes") or {}).get("certificateType") in REVOCABLE_TYPES


def is_api_created(cert: dict) -> bool:
    attrs = cert.get("attributes") or {}
    text = f"{attrs.get('name') or ''} {attrs.get('displayName') or ''}".lower()
    return API_CREATED_MARKER in text


def describe(cert: dict) -> str:
    a = cert.get("attributes") or {}
    return f"{cert.get('id')} type={a.get('certificateType')} name={a.get('name')!r} " \
           f"display={a.get('displayName')!r} expires={a.get('expirationDate')}"


def select_stale(certs: list[dict]) -> list[dict]:
    return [c for c in certs if is_development(c) and is_api_created(c)]


def select_new(certs: list[dict], before_ids: set[str]) -> list[dict]:
    return [c for c in certs if is_development(c) and c.get("id") not in before_ids]


def revoke_all(client: Client, targets: list[dict], dry_run: bool) -> int:
    failures = 0
    for cert in targets:
        if not is_development(cert):  # defence in depth: never revoke anything else
            continue
        if dry_run:
            print(f"[dry-run] would revoke {describe(cert)}")
            continue
        try:
            client.revoke(cert["id"])
            print(f"revoked {describe(cert)}")
        except urllib.error.HTTPError as e:
            failures += 1
            print(f"::warning::could not revoke certificate {cert.get('id')}: HTTP {e.code}")
    if not targets:
        print("nothing to revoke")
    return failures


def main(argv=None, client: Client | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["snapshot", "revoke-stale", "revoke-new"])
    p.add_argument("file", nargs="?", help="snapshot file (snapshot / revoke-new)")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)
    if args.command in ("snapshot", "revoke-new") and not args.file:
        p.error(f"{args.command} needs a snapshot file")

    if client is None:
        missing = [v for v in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not os.environ.get(v)]
        if missing:
            print(f"::warning::certificate cleanup skipped: {', '.join(missing)} not set")
            return 1
        client = Client(make_jwt(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"]))

    certs = client.list_certificates()
    dev = [c for c in certs if is_development(c)]
    print(f"{len(certs)} certificates in the team, {len(dev)} development "
          f"({len(select_stale(certs))} created via an API key)")

    if args.command == "snapshot":
        with open(args.file, "w") as f:
            json.dump(sorted(c["id"] for c in dev), f)
        return 0
    if args.command == "revoke-stale":
        return 1 if revoke_all(client, select_stale(certs), args.dry_run) else 0
    with open(args.file) as f:
        before = set(json.load(f))
    return 1 if revoke_all(client, select_new(certs, before), args.dry_run) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as e:
        print(f"::warning::App Store Connect API error: HTTP {e.code} {e.reason}")
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 - cleanup must never crash loudly with secrets; message only
        print(f"::warning::certificate cleanup failed: {type(e).__name__}: {e}")
        sys.exit(1)
