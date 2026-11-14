#!/usr/bin/env python3
"""Offline tests for asc_certs.py (no network, no real key). Run: python3 .github/release/test_asc_certs.py"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_certs  # noqa: E402


def cert(cid, ctype, name):
    return {"id": cid, "attributes": {"certificateType": ctype, "name": name, "displayName": name}}


CERTS = [
    cert("own-dev", "DEVELOPMENT", "Apple Development: Owner Name (ABC123)"),
    cert("ci-old-1", "DEVELOPMENT", "Apple Development: Created via API (TEAMID)"),
    cert("ci-old-2", "IOS_DEVELOPMENT", "iOS Development: Created via API"),
    cert("dist", "DISTRIBUTION", "Apple Distribution: Created via API"),
    cert("ios-dist", "IOS_DISTRIBUTION", "iOS Distribution: Owner Name"),
]


class FakeClient:
    def __init__(self, certs):
        self.certs, self.revoked = list(certs), []

    def list_certificates(self):
        return list(self.certs)

    def revoke(self, cid):
        self.revoked.append(cid)


class Tests(unittest.TestCase):
    def test_stale_only_api_created_development(self):
        fake = FakeClient(CERTS)
        self.assertEqual(asc_certs.main(["revoke-stale"], client=fake), 0)
        self.assertEqual(sorted(fake.revoked), ["ci-old-1", "ci-old-2"])

    def test_dry_run_revokes_nothing(self):
        fake = FakeClient(CERTS)
        asc_certs.main(["revoke-stale", "--dry-run"], client=fake)
        self.assertEqual(fake.revoked, [])

    def test_snapshot_then_revoke_new_never_touches_distribution(self):
        fake = FakeClient(CERTS)
        with tempfile.TemporaryDirectory() as d:
            snap = os.path.join(d, "snap.json")
            asc_certs.main(["snapshot", snap], client=fake)
            fake.certs += [cert("this-run", "DEVELOPMENT", "Apple Development: Created via API"),
                           cert("new-dist", "DISTRIBUTION", "Apple Distribution")]
            asc_certs.main(["revoke-new", snap], client=fake)
        self.assertEqual(fake.revoked, ["this-run"])

    def test_jwt_signature_verifies(self):
        with tempfile.TemporaryDirectory() as d:
            key = os.path.join(d, "k.p8")
            pub = os.path.join(d, "k.pub")
            # ecparam + pkcs8 works with both OpenSSL and macOS LibreSSL; .p8 files are PKCS#8 like this.
            sec1 = subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout"],
                                  check=True, capture_output=True).stdout
            subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-out", key], input=sec1,
                           check=True, capture_output=True)
            subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)
            token = asc_certs.make_jwt("KID", "ISS", key, now=1000)
            h, p, s = token.split(".")
            pad = lambda x: x + "=" * (-len(x) % 4)  # noqa: E731
            self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(p)))["exp"], 1600)
            raw = base64.urlsafe_b64decode(pad(s))
            self.assertEqual(len(raw), 64)
            # Re-encode r||s as DER and verify with openssl.
            def der_int(b):
                b = b.lstrip(b"\x00") or b"\x00"
                if b[0] & 0x80:
                    b = b"\x00" + b
                return b"\x02" + bytes([len(b)]) + b
            body = der_int(raw[:32]) + der_int(raw[32:])
            sig = os.path.join(d, "sig")
            with open(sig, "wb") as f:
                f.write(b"\x30" + bytes([len(body)]) + body)
            r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sig],
                               input=f"{h}.{p}".encode(), capture_output=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
