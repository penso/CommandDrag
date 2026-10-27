"""Release only an owner-created tag on main whose exact commit passed CI."""

import json
import os
import re
import subprocess
import time
import urllib.request

REPOSITORY = "penso/CommandDrag"
TAG_PATTERN = r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9]+(?:\.[a-zA-Z0-9]+)*)?"


def validate_context(tag, ref, sha, repository, actor, triggering_actor):
    if repository != REPOSITORY or actor != "penso" or triggering_actor != "penso":
        raise ValueError("Only the repository owner may publish from the canonical repository")
    if not re.fullmatch(TAG_PATTERN, tag):
        raise ValueError("Expected a vX.Y.Z or vX.Y.Z-rc.N release tag")
    if ref != f"refs/tags/{tag}":
        raise ValueError("Dispatch the workflow FROM the release tag, not main or another ref")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Expected a full source commit SHA")


def ci_state(runs, sha):
    matching = [run for run in runs if run["head_sha"] == sha and
                run["head_branch"] == "main" and run["event"] == "push" and
                run["head_repository"]["full_name"] == REPOSITORY]
    if not matching:
        return "pending"
    latest = max(matching, key=lambda run: (run["id"], run.get("run_attempt", 1)))
    if latest["status"] != "completed":
        return "pending"
    return "success" if latest["conclusion"] == "success" else "failure"


def main():
    tag, sha = os.environ["RELEASE_TAG"], os.environ["GITHUB_SHA"]
    validate_context(tag, os.environ["GITHUB_REF"], sha, os.environ["GITHUB_REPOSITORY"],
                     os.environ["GITHUB_ACTOR"], os.environ["GITHUB_TRIGGERING_ACTOR"])
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    tagged = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], text=True).strip()
    if head != sha or tagged != sha:
        raise ValueError("The checked-out source, tag, and workflow must identify the same commit")
    subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], check=True)

    url = (f"https://api.github.com/repos/{REPOSITORY}/actions/workflows/ci.yml/runs"
           f"?branch=main&event=push&head_sha={sha}&per_page=100")
    request = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    deadline = time.monotonic() + 20 * 60
    while True:
        with urllib.request.urlopen(request, timeout=30) as response:
            state = ci_state(json.load(response)["workflow_runs"], sha)
        if state == "success":
            break
        if state == "failure":
            raise ValueError("CI failed or was cancelled for this exact commit; signing is blocked")
        if time.monotonic() >= deadline:
            raise TimeoutError("Timed out waiting for this commit's main CI; rerun after CI succeeds")
        print(f"Waiting for main CI on {sha}…", flush=True)
        time.sleep(15)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"tag={tag}\nsha={sha}\n")
    print(f"Release validated: {tag} at {sha}, with successful main CI")


if __name__ == "__main__":
    main()
