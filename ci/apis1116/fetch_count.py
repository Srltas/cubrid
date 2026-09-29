#!/usr/bin/env python3
"""fetch_count.py mark <file> | count <file>

mark remembers where each SQL log ends; count prints, for the sub-type 21 results logged since,
"<results> <results read on over 3+ FETCHes> <cursor positions of those>".
"""
import glob
import json
import re
import sys

LOGS = "/home/CUBRID/log/broker/sql_log/*.sql.log"
mode, mark = sys.argv[1], sys.argv[2]

if mode == "mark":
    json.dump({f: sum(1 for _ in open(f, errors="replace")) for f in glob.glob(LOGS)}, open(mark, "w"))
    sys.exit(0)

start = json.load(open(mark))
runs = []
for f in sorted(glob.glob(LOGS)):
    pending, current = False, None
    for i, line in enumerate(open(f, errors="replace")):
        if i < start.get(f, 0):
            continue
        if "schema_info SCHEMAS" in line:
            pending = True
            continue
        # another request may take over the handle number
        if re.search(r"\) (schema_info [A-Z_]+ |prepare )", line):
            pending, current = False, None
            continue
        m = re.search(r"schema_info srv_h_id (\d+)", line)
        if m and pending:
            pending, current = False, m.group(1)
            runs.append([])
            continue
        m = re.search(r"fetch srv_h_id (\d+) cursor_pos (\d+)", line)
        if m and m.group(1) == current:
            runs[-1].append(int(m.group(2)))
            continue
        m = re.search(r"close_req_handle srv_h_id (\d+)", line)
        if m and m.group(1) == current:
            current = None

# a result read on in order: the first FETCH at 1, each next one further on
multi = [r for r in runs if len(r) >= 3 and r[0] == 1 and all(b > a for a, b in zip(r, r[1:]))]
print(len(runs), len(multi), sorted(set(tuple(r) for r in multi))[:3])
