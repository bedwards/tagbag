#!/usr/bin/env python3
"""Bidirectional issue sync between Plane and GitHub.

Uses HTML comment markers to track paired issues:
  <!-- tagbag:plane-issue:MEM-123 -->  (embedded in GitHub issue body)
  <!-- tagbag:github-issue:456 -->     (appended to Plane description)

Syncs: title, body/description, state (open/closed ↔ Todo/Done)
Direction: Plane → GitHub, then GitHub → Plane
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.request
from datetime import datetime

PLANE_MARKER = "<!-- tagbag:plane-issue:{} -->"
GITHUB_MARKER = "<!-- tagbag:github-issue:{} -->"
PLANE_MARKER_RE = re.compile(r"<!-- tagbag:plane-issue:([\w-]+) -->")
GITHUB_MARKER_RE = re.compile(r"<!-- tagbag:github-issue:(\d+) -->")


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[issue-sync] [{ts}] {msg}", flush=True)


def plane_api(base_url, token, method, path, data=None):
    url = f"{base_url}/api/v1{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        url, data=body, method=method,
        headers={
            "X-Api-Key": token,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode() if e.fp else ""
        log(f"  Plane API error {e.code} on {method} {path}: {err_body[:200]}")
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


def fetch_all_plane_items(base_url, token, workspace, project_id):
    """Fetch all work items from a Plane project."""
    items = []
    # Plane API doesn't paginate the same way; fetch with large limit
    result = plane_api(base_url, token, "GET",
                       f"/workspaces/{workspace}/projects/{project_id}/work-items/")
    if result:
        items = result.get("results", result) if isinstance(result, dict) else result
    return items if isinstance(items, list) else []


def fetch_all_github_issues(gh_repo):
    """Fetch all issues (not PRs) from GitHub, paginating."""
    issues = []
    page = 1
    while True:
        batch = gh_api("GET", f"repos/{gh_repo}/issues?state=all&per_page=100&page={page}")
        if not batch:
            break
        batch = [i for i in batch if "pull_request" not in i]
        issues.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return issues


def find_marker(body, pattern):
    if not body:
        return None
    m = pattern.search(body)
    return m.group(1) if m else None


def strip_sync_footer(body):
    if not body:
        return ""
    body = re.sub(r"\n*---\n\*Synced from (Plane|GitHub) .*?\*\n<!-- tagbag:.*?-->\s*$", "", body)
    body = re.sub(r"\n*<!-- tagbag:(plane|github)-issue:[\w-]+ -->\s*$", "", body)
    return body.rstrip()


def html_to_plain(html):
    """Very basic HTML to plain text for Plane descriptions."""
    if not html:
        return ""
    text = re.sub(r"<br\s*/?>", "\n", html)
    text = re.sub(r"<p>", "", text)
    text = re.sub(r"</p>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plane-url", required=True)
    parser.add_argument("--plane-token", required=True)
    parser.add_argument("--plane-workspace", required=True)
    parser.add_argument("--plane-project-id", required=True)
    parser.add_argument("--plane-project-identifier", required=True)
    parser.add_argument("--github-repo", required=True)
    parser.add_argument("--todo-state-id", required=True)
    parser.add_argument("--done-state-id", required=True)
    args = parser.parse_args()

    plane_items = fetch_all_plane_items(args.plane_url, args.plane_token,
                                         args.plane_workspace, args.plane_project_id)
    gh_issues = fetch_all_github_issues(args.github_repo)
    log(f"Plane: {len(plane_items)} work items, GitHub: {len(gh_issues)} issues")

    # Build lookup maps
    # GitHub issues indexed by their Plane marker
    gh_by_plane_id = {}
    for gi in gh_issues:
        pid = find_marker(gi.get("body", ""), PLANE_MARKER_RE)
        if pid is not None:
            gh_by_plane_id[pid] = gi

    # Plane items indexed by their GitHub marker
    plane_by_github_id = {}
    for pi in plane_items:
        desc = pi.get("description_stripped") or html_to_plain(pi.get("description_html") or "")
        ghid = find_marker(desc, GITHUB_MARKER_RE)
        if ghid is not None:
            plane_by_github_id[int(ghid)] = pi

    # State mapping
    completed_groups = {"completed", "cancelled"}

    # ── Plane → GitHub ──────────────────────────────────────────────────
    log("=== Plane → GitHub ===")
    created_gh = 0
    updated_gh = 0

    for pi in plane_items:
        seq = pi.get("sequence_id", "")
        plane_key = f"{args.plane_project_identifier}-{seq}"
        pi_title = pi.get("name", "")
        pi_desc = pi.get("description_stripped") or html_to_plain(pi.get("description_html") or "")
        clean_desc = strip_sync_footer(pi_desc)

        # Determine state
        state_detail = pi.get("state_detail")
        if isinstance(state_detail, dict):
            state_group = state_detail.get("group", "")
        else:
            # state is a string ID, compare directly
            state_id = pi.get("state", "")
            state_group = "completed" if state_id == args.done_state_id else "unstarted"
        pi_is_closed = state_group in completed_groups

        if plane_key in gh_by_plane_id:
            gi = gh_by_plane_id[plane_key]
            gi_state = gi["state"]
            needs_update = False
            if gi["title"] != pi_title:
                needs_update = True
            if (gi_state == "closed") != pi_is_closed:
                needs_update = True
            if needs_update:
                marker = PLANE_MARKER.format(plane_key)
                synced_body = f"{clean_desc}\n\n---\n*Synced from Plane {plane_key}*\n{marker}"
                gh_api("PATCH", f"repos/{args.github_repo}/issues/{gi['number']}", {
                    "title": pi_title,
                    "body": synced_body,
                    "state": "closed" if pi_is_closed else "open",
                })
                updated_gh += 1
                log(f"  Updated GitHub #{gi['number']} ← Plane {plane_key}")
        else:
            marker = PLANE_MARKER.format(plane_key)
            synced_body = f"{clean_desc}\n\n---\n*Synced from Plane {plane_key}*\n{marker}"
            result = gh_api("POST", f"repos/{args.github_repo}/issues", {
                "title": pi_title,
                "body": synced_body,
            })
            if result and "number" in result:
                gh_num = result["number"]
                created_gh += 1
                if pi_is_closed:
                    gh_api("PATCH", f"repos/{args.github_repo}/issues/{gh_num}", {
                        "state": "closed",
                    })
                log(f"  Created GitHub #{gh_num} ← Plane {plane_key}: {pi_title}")
            else:
                log(f"  FAILED to create GitHub issue for Plane {plane_key}")

    log(f"  Plane → GitHub: {created_gh} created, {updated_gh} updated")

    # ── GitHub → Plane ──────────────────────────────────────────────────
    log("=== GitHub → Plane ===")
    created_plane = 0
    updated_plane = 0

    for gi in gh_issues:
        gi_num = gi["number"]
        gi_title = gi["title"]
        gi_body = gi.get("body") or ""
        gi_state = gi["state"]
        clean_body = strip_sync_footer(gi_body)

        # Skip issues that originated from Plane
        if find_marker(gi_body, PLANE_MARKER_RE) is not None:
            continue

        gi_is_closed = gi_state == "closed"
        state_id = args.done_state_id if gi_is_closed else args.todo_state_id

        if gi_num in plane_by_github_id:
            pi = plane_by_github_id[gi_num]
            pi_title = pi.get("name", "")
            pi_state_detail = pi.get("state_detail")
            if isinstance(pi_state_detail, dict):
                pi_state_group = pi_state_detail.get("group", "")
            else:
                pi_sid = pi.get("state", "")
                pi_state_group = "completed" if pi_sid == args.done_state_id else "unstarted"
            pi_is_closed = pi_state_group in completed_groups

            needs_update = False
            if pi_title != gi_title:
                needs_update = True
            if pi_is_closed != gi_is_closed:
                needs_update = True

            if needs_update:
                plane_api(args.plane_url, args.plane_token, "PATCH",
                          f"/workspaces/{args.plane_workspace}/projects/{args.plane_project_id}/work-items/{pi['id']}/",
                          {"name": gi_title, "state": state_id})
                updated_plane += 1
                log(f"  Updated Plane {args.plane_project_identifier}-{pi.get('sequence_id','')} ← GitHub #{gi_num}")
        else:
            marker = GITHUB_MARKER.format(gi_num)
            desc_html = f"<p>{clean_body}</p><p>{marker}</p>" if clean_body else f"<p>{marker}</p>"
            result = plane_api(args.plane_url, args.plane_token, "POST",
                               f"/workspaces/{args.plane_workspace}/projects/{args.plane_project_id}/work-items/",
                               {"name": gi_title, "description_html": desc_html, "state": state_id})
            if result and "id" in result:
                created_plane += 1
                log(f"  Created Plane {args.plane_project_identifier}-{result.get('sequence_id','')} ← GitHub #{gi_num}: {gi_title}")
            else:
                log(f"  FAILED to create Plane work item for GitHub #{gi_num}")

    log(f"  GitHub → Plane: {created_plane} created, {updated_plane} updated")
    log(f"Sync complete: Plane {args.plane_project_identifier} ↔ github.com/{args.github_repo}")


if __name__ == "__main__":
    main()
