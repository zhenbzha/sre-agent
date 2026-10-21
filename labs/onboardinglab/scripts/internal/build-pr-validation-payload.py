#!/usr/bin/env python3
"""Collect immutable review evidence; never check out or execute PR content."""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote


MAX_CHANGED_FILES = 100
MAX_FILE_BYTES = 64 * 1024
MAX_PAYLOAD_BYTES = 256 * 1024
APP = "labs/onboardinglab/ticketingapp-source/app/"
CONTEXT_PATHS = tuple(APP + path for path in (
    "database.js", "handler.js", "server.js", "package.json", "README.md",
    "public/app.js", "test/handler.test.js",
))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def github_api(path):
    result = subprocess.run(
        ["gh", "api", "-H", "Accept: application/vnd.github+json", path],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    return json.loads(result.stdout)


def slug(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value),
            "Invalid repository identity.")
    return value


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value),
            "Invalid immutable commit or blob SHA.")
    return value


def source_path(value):
    require(isinstance(value, str) and value and
            not any(ord(char) < 32 or ord(char) == 127 for char in value) and
            "\\" not in value and
            all(part not in ("", ".", "..") for part in value.split("/")),
            "Invalid source path.")
    return value


def pr_identity(pr):
    return (
        pr["number"], pr["html_url"], pr["base"]["repo"]["full_name"],
        pr["base"]["ref"], pr["base"]["sha"], pr["head"]["repo"]["full_name"],
        pr["head"]["ref"], pr["head"]["sha"],
    )


def serialize(payload):
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    require(len(encoded) <= MAX_PAYLOAD_BYTES,
            "Review evidence exceeds 256 KiB; split the PR. Nothing was delivered.")
    return encoded


def build_payload(event, repository, api=github_api):
    repository = slug(repository)
    require(event.get("action") in ("opened", "synchronize", "reopened"),
            "Unsupported pull-request action.")
    pr = event["pull_request"]
    number = pr["number"]
    require(type(number) is int and number > 0, "Invalid PR number.")
    require(event["repository"]["full_name"] == repository and
            pr["base"]["repo"]["full_name"] == repository and
            pr["html_url"] == f"https://github.com/{repository}/pull/{number}",
            "Event repository or PR URL does not match the trusted workflow.")
    base_sha = sha(pr["base"]["sha"])
    head_sha = sha(pr["head"]["sha"])
    head_repo = slug(pr["head"]["repo"]["full_name"])
    pr_endpoint = f"repos/{repository}/pulls/{number}"
    current = api(pr_endpoint)
    require(current["state"] == "open" and pr_identity(current) == pr_identity(pr),
            "PR changed since this event; use its latest event instead.")
    count = current["changed_files"]
    require(type(count) is int and 0 < count <= MAX_CHANGED_FILES,
            "PR must contain between 1 and 100 changed files.")

    comparison = api(
        f"repos/{repository}/compare/{base_sha}..."
        f"{quote(head_repo.split('/')[0], safe='')}:{head_sha}?per_page=1"
    )
    require(comparison["base_commit"]["sha"] == base_sha,
            "Comparison base does not match the event.")
    merge_base = sha(comparison["merge_base_commit"]["sha"])
    changes = comparison["files"]
    require(len(changes) == count, "Incomplete changed-file evidence; nothing was delivered.")
    before_paths, after_paths, removed_paths = set(), set(), set()
    changed_files = []
    for change in changes:
        path = source_path(change["filename"])
        status = change["status"]
        require(status in ("added", "modified", "removed", "renamed"),
                f"Unsupported change type for {path}: {status}.")
        require(isinstance(change.get("patch"), str) and change["patch"],
                f"Missing text patch for {path}; nothing was delivered.")
        previous = source_path(change.get("previous_filename", path))
        if status != "added":
            before_paths.add(previous)
        if status != "removed":
            after_paths.add(path)
        else:
            removed_paths.add(path)
        changed_files.append({key: change[key] for key in (
            "filename", "previous_filename", "status", "additions",
            "deletions", "changes", "patch",
        ) if key in change})
    require(len({change["filename"] for change in changes}) == count,
            "Duplicate changed-file paths.")

    snapshots = []
    blobs = {}
    for label, repo, commit, paths in (
        ("merge_base", repository, merge_base, before_paths),
        ("head", head_repo, head_sha, after_paths | set(CONTEXT_PATHS)),
    ):
        tree = api(f"repos/{repo}/git/trees/{commit}?recursive=1")
        require(tree.get("truncated") is False, "Source tree was truncated; nothing was delivered.")
        entries = {entry["path"]: entry for entry in tree["tree"]}
        files = []
        for path in sorted(paths):
            entry = entries.get(path)
            if label == "head" and path in removed_paths:
                require(entry is None, f"Removed path still exists at the PR head: {path}.")
                files.append({"path": path, "absent": True})
                continue
            require(entry is not None, f"Required {label} source is missing: {path}.")
            require(entry["type"] == "blob" and entry["mode"] in ("100644", "100755"),
                    f"Only regular source files can be reviewed: {path}.")
            require(type(entry.get("size")) is int and 0 <= entry["size"] <= MAX_FILE_BYTES,
                    f"Source file exceeds 64 KiB or has no size: {path}.")
            blob_sha = sha(entry["sha"])
            if blob_sha not in blobs:
                blob = api(f"repos/{repo}/git/blobs/{blob_sha}")
                require(blob.get("sha") == blob_sha and blob.get("encoding") == "base64",
                        f"Invalid blob response for {path}.")
                data = base64.b64decode("".join(blob["content"].split()), validate=True)
                require(len(data) == entry["size"] == blob["size"],
                        f"Incomplete source content for {path}.")
                digest = hashlib.sha1(
                    b"blob " + str(len(data)).encode("ascii") + b"\0" + data
                ).hexdigest()
                require(digest == blob_sha, f"Source integrity mismatch for {path}.")
                content = data.decode("utf-8")
                require("\0" not in content, f"Binary source cannot be reviewed: {path}.")
                blobs[blob_sha] = content
            files.append({"path": path, "blob_sha": blob_sha, "content": blobs[blob_sha]})
        snapshots.append({"role": label, "repo": repo, "commit_sha": commit, "files": files})

    payload = {
        "schema_version": 2,
        "event": "pull_request", "action": event["action"],
        "repo": repository, "pr_number": number, "pr_url": pr["html_url"],
        "pr_diff_url": pr["diff_url"], "pr_author": pr["user"]["login"],
        "base_ref": pr["base"]["ref"], "base_sha": base_sha,
        "merge_base_sha": merge_base, "head_repo": head_repo,
        "head_ref": pr["head"]["ref"], "head_sha": head_sha,
        "changed_files": changed_files, "source_snapshots": snapshots,
    }
    serialize(payload)
    latest = api(pr_endpoint)
    require(latest["state"] == "open" and pr_identity(latest) == pr_identity(pr) and
            latest["changed_files"] == count,
            "PR changed while evidence was collected; nothing was delivered.")
    return payload


def main():
    require(os.environ.get("GITHUB_EVENT_NAME") == "pull_request_target",
            "Only the trusted pull_request_target workflow may deliver this payload.")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    payload = build_payload(event, os.environ["GITHUB_REPOSITORY"])
    sys.stdout.buffer.write(serialize(payload))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print(f"PR evidence collection failed: {error}", file=sys.stderr)
        sys.exit(1)
