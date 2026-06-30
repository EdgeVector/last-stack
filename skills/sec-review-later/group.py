#!/usr/bin/env python3
"""Group [sec-review-later] commits (sha\\tsubject on stdin) into sprint buckets
and print a review digest. Driven by scan.sh; reads env REPO, THEME, BOUND_DESC."""
import os, re, subprocess, sys

repo = os.environ["REPO"]
theme_filter = os.environ.get("THEME", "").strip()
bound = os.environ.get("BOUND_DESC", "")

rows = [l.rstrip("\n").split("\t", 1) for l in sys.stdin if "\t" in l]

# Bucket rules: (key, regex over subject). First match wins; order matters.
BUCKETS = [
    ("at-rest-encryption", r"at-rest|crypto|storage|secure[_-]store|keyring|encrypt|zeroize|argon2|envelope"),
    ("app-isolation",      r"app-isolation|app-iso|uds|data[-_]share|discovery|loopback|owner-verb|host[-_]guard|attest|isolation"),
    ("wasm-transforms",    r"wasm|transform"),
    ("app-identity-uses",  r"app-identity|\[uses\]|capability|consent|revoc|dev-cert|auth_service|developer"),
]

def bucket(subj):
    s = subj.lower()
    for key, pat in BUCKETS:
        if re.search(pat, s):
            return key
    return "other"

def prnum(subj):
    m = re.search(r"\(#(\d+)\)\s*$", subj)
    return m.group(1) if m else None

groups = {}
for sha, subj in rows:
    if theme_filter and theme_filter not in bucket(subj):
        continue
    groups.setdefault(bucket(subj), []).append((sha, subj))

print("# [sec-review-later] backlog digest")
total = sum(len(v) for v in groups.values())
print(f"_scope: {bound}_   _flagged commits in scope: {total}_\n")
if not total:
    print("Nothing flagged in scope. Backlog is clear — record a checkpoint if you just reviewed.\n")
    sys.exit(0)

for key in sorted(groups, key=lambda k: -len(groups[k])):
    commits = groups[key]
    shas = [c[0] for c in commits]
    prs = sorted({p for c in commits if (p := prnum(c[1]))}, key=int)
    oldest, newest = shas[-1], shas[0]   # git log is newest-first
    rng = f"{oldest}^..{newest}"
    # NB: do NOT pass --no-patch/-s here — it suppresses --name-only too.
    files = subprocess.run(
        ["git", "-C", repo, "show", "--name-only", "--pretty=format:", *shas],
        capture_output=True, text=True,
    ).stdout
    seen, flist = set(), []
    for f in files.splitlines():
        f = f.strip()
        if f and f not in seen:
            seen.add(f); flist.append(f)
    flist.sort()
    print(f"## sprint bucket: `{key}`  ({len(commits)} commits, {len(prs)} PRs)")
    print(f"- review range: `{rng}`")
    if prs:
        print(f"- PRs: {', '.join('#' + p for p in prs)}")
    print("- commits:")
    for sha, subj in commits:
        print(f"    - {sha[:9]} {subj}")
    print(f"- changed files ({len(flist)}):")
    for f in flist[:60]:
        print(f"    - {f}")
    if len(flist) > 60:
        print(f"    - … +{len(flist)-60} more (git show --name-only {oldest[:9]}..{newest[:9]})")
    print()
