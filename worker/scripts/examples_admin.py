#!/usr/bin/env python3
"""Review submissions to the Manimble Examples page.

    examples_admin.py list [pending|approved|rejected]
    examples_admin.py download ID [-o FILE]    # then: manimbler --check FILE
    examples_admin.py approve ID
    examples_admin.py reject ID                # deletes the uploaded package

The admin token is read from $MANIMBLE_EXAMPLES_ADMIN_TOKEN, or else from the macOS Keychain
(service "manimble-examples-admin"). It is the Worker's ADMIN_TOKEN secret.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

SERVICE = os.environ.get("MANIMBLE_EXAMPLES_URL", "https://api.manimble.com").rstrip("/")
KEYCHAIN = "manimble-examples-admin"


def token() -> str:
    value = os.environ.get("MANIMBLE_EXAMPLES_ADMIN_TOKEN")
    if value:
        return value
    try:
        return subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN, "-w"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit(f"No admin token: set MANIMBLE_EXAMPLES_ADMIN_TOKEN or add it to the Keychain as {KEYCHAIN!r}")


def call(method: str, path: str) -> dict:
    request = urllib.request.Request(SERVICE + path, method=method,
                                     headers={"authorization": f"Bearer {token()}",
                                              "user-agent": "manimble-examples-admin"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            message = json.load(error).get("error", error.reason)
        except ValueError:
            message = error.reason
        sys.exit(f"{error.code}: {message}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("status", nargs="?", default="pending", choices=("pending", "approved", "rejected"))
    download = commands.add_parser("download")
    download.add_argument("id")
    download.add_argument("-o", "--output")
    for name in ("approve", "reject"):
        commands.add_parser(name).add_argument("id")
    args = parser.parse_args()

    if args.command == "list":
        examples = call("GET", f"/admin/examples?status={args.status}")["examples"]
        if not examples:
            print(f"No {args.status} examples.")
        for e in examples:
            print(f"{e['id']}  {e['submitted'][:10]}  {e['size'] / 1e6:.1f} MB  {e['title']} — {e['authors']}")
            if e.get("issue_url"):
                print(f"    {e['issue_url']}")
    elif args.command == "download":
        output = args.output or f"{args.id}.manimble"
        request = urllib.request.Request(f"{SERVICE}/examples/{args.id}/package",
                                         headers={"user-agent": "manimble-examples-admin"})
        with urllib.request.urlopen(request, timeout=300) as response, open(output, "wb") as file:
            shutil.copyfileobj(response, file)
        print(f"Saved {output}. Check it with: manimbler --check {output}")
    else:
        result = call("POST", f"/admin/examples/{args.id}/{args.command}")
        print(f"{result['id']}: {result['status']}")


if __name__ == "__main__":
    main()
