#!/usr/bin/env python3
"""summarize.py <dir>: Markdown tables of the checks, one per job kind, a column per engine version.

<dir> is one job's out/ folder, or the folder holding every job's result-<kind>-<version>/ artifact.
"""
import glob
import json
import os
import sys

VERSIONS = ["develop", "11.4", "11.3", "11.2"]
KINDS = ["verify", "ctp"]


def esc(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def load(d):
    meta_path = os.path.join(d, "meta.json")
    if os.path.exists(meta_path):
        meta = json.load(open(meta_path))
    else:
        _, kind, version = (os.path.basename(d.rstrip("/")) + "--").split("-")[:3]
        meta = {"kind": kind, "version": version}
    results_path = os.path.join(d, "results.jsonl")
    rows = [json.loads(line) for line in open(results_path)] if os.path.exists(results_path) else []
    return meta, rows


root = sys.argv[1]
single = os.path.exists(os.path.join(root, "meta.json")) or os.path.exists(os.path.join(root, "results.jsonl"))
jobs = {}
for d in [root] if single else sorted(glob.glob(os.path.join(root, "*"))):
    meta, rows = load(d)
    jobs[(meta.get("kind"), meta.get("version"))] = (meta, rows)

out = [] if single else ["## APIS-1116 verification", ""]
for kind in KINDS:
    versions = [v for v in VERSIONS if (kind, v) in jobs]
    if not versions:
        continue
    checks = []
    for v in versions:
        for r in jobs[(kind, v)][1]:
            if r["check"] not in checks:
                checks.append(r["check"])
    recorded = sum(len(jobs[(kind, v)][1]) for v in versions)
    failed = sum(1 for v in versions for r in jobs[(kind, v)][1] if not r["pass"])
    state = "no check was recorded" if recorded == 0 else "all checks pass" if failed == 0 else "%d failed" % failed
    out += ["### %s: %s" % (kind, state), "",
            "| check | %s |" % " | ".join(versions), "|---|%s" % ("---|" * len(versions))]
    for c in checks:
        cells = []
        for v in versions:
            r = next((r for r in jobs[(kind, v)][1] if r["check"] == c), None)
            cells.append("" if r is None else "✅" if r["pass"] else "❌ " + esc(r["actual"])[:80])
        out.append("| %s | %s |" % (esc(c), " | ".join(cells)))
    empty = [v for v in versions if not jobs[(kind, v)][1]]
    if empty:
        out += ["", "No check was recorded for %s: see the job log." % ", ".join(empty)]
    missing = [v for v in VERSIONS if (kind, v) not in jobs]
    if missing and not single:
        out += ["", "No result was uploaded for %s." % ", ".join(missing)]
    out.append("")

order = sorted(jobs.items(), key=lambda kv: (KINDS.index(kv[0][0]) if kv[0][0] in KINDS else 9,
                                             VERSIONS.index(kv[0][1]) if kv[0][1] in VERSIONS else 9))
commits = [m for _, (m, _) in order if "engine" in m]
if commits:
    out += ["| engine | patch | base |", "|---|---|---|"]
    seen = set()
    for m in commits:
        if m["version"] in seen:
            continue
        seen.add(m["version"])
        out.append("| %s (`%s`) | `%s` | `%s` |" % (m["version"], m["engine_branch"], m["engine"][:10], m["engine_base"][:10]))
    m = commits[0]
    out += ["", "driver `%s` (base `%s`), TCs `%s` (base `%s`)" % (
        m["driver"][:10], m["driver_base"][:10], m["tc"][:10], m["tc_base"][:10]), ""]
print("\n".join(out))
