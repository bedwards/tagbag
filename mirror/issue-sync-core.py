#!/usr/bin/env python3
"""Bidirectional issue sync between Gitea and GitHub.

Uses HTML comment markers to track paired issues:
  <!-- tagbag:gitea-issue:123 -->   (embedded in GitHub issue body)
  <!-- tagbag:github-issue:456 -->  (embedded in Gitea issue body)

Syncs: title, body, state (open/closed)
Direction: Gitea → GitHub, then GitHub → Gitea
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.request
from datetime import datetime

GITEA_MARKER = "<!-- tagbag:gitea-issue:{} -->"
GITHUB_MARKER = "<!-- tagbag:github-issue:{} -->"
GITEA_MARKER_RE = re.compile(r"<!-- tagbag:gitea-issue:(\d+) -->")
GITHUB_MARKER_RE = re.compile(r"<!-- tagbag:github-issue:(\d+) -->")


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[issue-sync] [{ts}] {msg}", flush=True)


def gitea_api(base_url, token, method, path, data=None):
    url = f"{base_url}/api/v1{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        url, data=body, method=method,
        headers={
            "Authorization": f"token {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode() if e.fp else ""
        log(f"  Gitea API error {e.code} on {method} {path}: {err_body[:200]}")
        return None


def gh_api(method, path, data=None):
    cmd = ["gh", "api", path, "-X", method]
    if data:
        for k, v in data.items():
            cmd += ["-f", f"{k}={v}"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            log(f"  gh API error on {method} {path}: {result.stderr[:200]}")
            return None
        return json.loads(result.stdout) if result.stdout.strip() else None
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        log(f"  gh API exception on {method} {path}: {e}")
        return None


def fetch_all_gitea_issues(base_url, token, repo):
    """Fetch all issues (not PRs) from Gitea, paginating."""
    issues = []
    page = 1
    while True:
        batch = gitea_api(base_url, token, "GET",
                          f"/repos/{repo}/issues?state=all&type=issues&limit=50&page={page}")
        if not batch:
            break
        issues.extend(batch)
        if len(batch) < 50:
            break
        page += 1
    return issues


def fetch_all_github_issues(gh_repo):
    """Fetch all issues (not PRs) from GitHub, paginating."""
    issues = []
    page = 1
    while True:
        batch = gh_api("GET", f"repos/{gh_repo}/issues?state=all&per_page=100&page={page}")
        if not batch:
            break
        # GitHub includes PRs in issues endpoint
        batch = [i for i in batch if "pull_request" not in i]
        issues.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return issues


def find_marker(body, pattern):
    """Find a sync marker in issue body, return the matched ID or None."""
    if not body:
        return None
    m = pattern.search(body)
    return int(m.group(1)) if m else None


def strip_sync_footer(body):
    """Remove the sync footer (--- + Synced from... + marker) from body."""
    if not body:
        return ""
    # Remove trailing sync block
    body = re.sub(r"\n*---\n\*Synced from (Gitea|GitHub) #\d+\*\n<!-- tagbag:.*?-->\s*$", "", body)
    # Remove standalone markers
    body = re.sub(r"\n*<!-- tagbag:(gitea|github)-issue:\d+ -->\s*$", "", body)
    return body.rstrip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gitea-url", required=True)
    parser.add_argument("--gitea-token", required=True)
    parser.add_argument("--gitea-repo", required=True)
    parser.add_argument("--github-repo", required=True)
    args = parser.parse_args()

    gitea_issues = fetch_all_gitea_issues(args.gitea_url, args.gitea_token, args.gitea_repo)
    gh_issues = fetch_all_github_issues(args.github_repo)
    log(f"Gitea: {len(gitea_issues)} issues, GitHub: {len(gh_issues)} issues")

    # Build lookup maps
    # GitHub issues indexed by their gitea marker (if any)
    gh_by_gitea_id = {}
    for gi in gh_issues:
        gid = find_marker(gi.get("body", ""), GITEA_MARKER_RE)
        if gid is not None:
            gh_by_gitea_id[gid] = gi

    # Gitea issues indexed by their github marker (if any)
    gitea_by_github_id = {}
    for ti in gitea_issues:
        ghid = find_marker(ti.get("body", ""), GITHUB_MARKER_RE)
        if ghid is not None:
            gitea_by_github_id[ghid] = ti

    # ── Gitea → GitHub ──────────────────────────────────────────────────
    log("=== Gitea → GitHub ===")
    created_gh = 0
    updated_gh = 0

    for ti in gitea_issues:
        ti_num = ti["number"]
        ti_title = ti["title"]
        ti_body = ti.get("body") or ""
        ti_state = ti["state"]  # open or closed
        clean_body = strip_sync_footer(ti_body)

        if ti_num in gh_by_gitea_id:
            # Already paired — check for updates
            gi = gh_by_gitea_id[ti_num]
            gi_state = gi["state"]
            gi_title = gi["title"]

            needs_update = False
            if gi_title != ti_title:
                needs_update = True
            if gi_state != ti_state:
                needs_update = True

            if needs_update:
                marker = GITEA_MARKER.format(ti_num)
                synced_body = f"{clean_body}\n\n---\n*Synced from Gitea #{ti_num}*\n{marker}"
                gh_api("PATCH", f"repos/{args.github_repo}/issues/{gi['number']}", {
                    "title": ti_title,
                    "body": synced_body,
                    "state": ti_state,
                })
                updated_gh += 1
                log(f"  Updated GitHub #{gi['number']} ← Gitea #{ti_num}")
        else:
            # New — create on GitHub
            marker = GITEA_MARKER.format(ti_num)
            synced_body = f"{clean_body}\n\n---\n*Synced from Gitea #{ti_num}*\n{marker}"
            result = gh_api("POST", f"repos/{args.github_repo}/issues", {
                "title": ti_title,
                "body": synced_body,
            })
            if result and "number" in result:
                gh_num = result["number"]
                created_gh += 1
                log(f"  Created GitHub #{gh_num} ← Gitea #{ti_num}: {ti_title}")

                # Close on GitHub if closed on Gitea
                if ti_state == "closed":
                    gh_api("PATCH", f"repos/{args.github_repo}/issues/{gh_num}", {
                        "state": "closed",
                    })

                # Add reverse marker on Gitea issue
                reverse_marker = GITHUB_MARKER.format(gh_num)
                if reverse_marker not in ti_body:
                    updated_gitea_body = f"{ti_body}\n\n{reverse_marker}" if ti_body else reverse_marker
                    gitea_api(args.gitea_url, args.gitea_token, "PATCH",
                              f"/repos/{args.gitea_repo}/issues/{ti_num}",
                              {"body": updated_gitea_body})
            else:
                log(f"  FAILED to create GitHub issue for Gitea #{ti_num}")

    log(f"  Gitea → GitHub: {created_gh} created, {updated_gh} updated")

    # ── GitHub → Gitea ──────────────────────────────────────────────────
    log("=== GitHub → Gitea ===")
    created_gitea = 0
    updated_gitea = 0

    for gi in gh_issues:
        gi_num = gi["number"]
        gi_title = gi["title"]
        gi_body = gi.get("body") or ""
        gi_state = gi["state"]
        clean_body = strip_sync_footer(gi_body)

        # Skip issues that originated from Gitea (have gitea marker)
        if find_marker(gi_body, GITEA_MARKER_RE) is not None:
            continue

        if gi_num in gitea_by_github_id:
            # Already paired — check for updates
            ti = gitea_by_github_id[gi_num]
            ti_state = ti["state"]
            ti_title = ti["title"]

            needs_update = False
            if ti_title != gi_title:
                needs_update = True
            if ti_state != gi_state:
                needs_update = True

            if needs_update:
                marker = GITHUB_MARKER.format(gi_num)
                synced_body = f"{clean_body}\n\n---\n*Synced from GitHub #{gi_num}*\n{marker}"
                gitea_api(args.gitea_url, args.gitea_token, "PATCH",
                          f"/repos/{args.gitea_repo}/issues/{ti['number']}",
                          {"title": gi_title, "body": synced_body, "state": gi_state})
                updated_gitea += 1
                log(f"  Updated Gitea #{ti['number']} ← GitHub #{gi_num}")
        else:
            # New GitHub issue — create on Gitea
            marker = GITHUB_MARKER.format(gi_num)
            synced_body = f"{clean_body}\n\n---\n*Synced from GitHub #{gi_num}*\n{marker}"
            result = gitea_api(args.gitea_url, args.gitea_token, "POST",
                               f"/repos/{args.gitea_repo}/issues",
                               {"title": gi_title, "body": synced_body})
            if result and "number" in result:
                gitea_num = result["number"]
                created_gitea += 1
                log(f"  Created Gitea #{gitea_num} ← GitHub #{gi_num}: {gi_title}")

                # Close on Gitea if closed on GitHub
                if gi_state == "closed":
                    gitea_api(args.gitea_url, args.gitea_token, "PATCH",
                              f"/repos/{args.gitea_repo}/issues/{gitea_num}",
                              {"state": "closed"})

                # Add reverse marker on GitHub issue
                reverse_marker = GITEA_MARKER.format(gitea_num)
                if reverse_marker not in gi_body:
                    updated_gh_body = f"{gi_body}\n\n{reverse_marker}" if gi_body else reverse_marker
                    gh_api("PATCH", f"repos/{args.github_repo}/issues/{gi_num}", {
                        "body": updated_gh_body,
                    })
            else:
                log(f"  FAILED to create Gitea issue for GitHub #{gi_num}")

    log(f"  GitHub → Gitea: {created_gitea} created, {updated_gitea} updated")
    log(f"Sync complete: {args.gitea_repo} ↔ github.com/{args.github_repo}")


if __name__ == "__main__":
    main()
