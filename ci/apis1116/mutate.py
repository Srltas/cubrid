#!/usr/bin/env python3
"""mutate.py <engine source> <mutant>: one change to the patched CAS; `git checkout -- src/broker` undoes it.

Every edit is scoped to one function and must match exactly once there, so a branch whose code
is shaped differently fails loudly instead of being changed somewhere else.
"""
import re
import sys

src, name = sys.argv[1], sys.argv[2]


def edit(path, func, subs):
    full = "%s/src/broker/%s" % (src, path)
    text = open(full, encoding="utf-8").read()
    m = re.search(r"^%s \(.*?^\}" % re.escape(func), text, re.M | re.S)
    if not m:
        raise ValueError("no function %s in %s" % (func, path))
    body = m.group(0)
    for pattern, repl in subs:
        body, n = re.subn(pattern, repl, body)
        if n != 1:
            raise ValueError("%r matches %d times in %s" % (pattern, n, func))
    open(full, "w", encoding="utf-8").write(text[:m.start()] + body + text[m.end():])


OR_21 = r"\s*\|\|\s*%s == CCI_SCH_SCHEMAS"


def close_list():
    # an if condition up to 11.4, a case label in develop
    try:
        edit("cas_handle.c", "srv_handle_content_free", [(OR_21 % "srv_handle->schema_type", "")])
    except ValueError:
        edit("cas_handle.c", "srv_handle_content_free", [(r"\n[ \t]*case CCI_SCH_SCHEMAS:", "")])


MUTANTS = {
    "cursor-list": lambda: edit("cas_execute.c", "ux_schema_info", [(OR_21 % "schema_type", "")]),
    "commit-list": lambda: edit("cas_handle.c", "hm_srv_handle_qresult_end_all",
                                [(OR_21 % "srv_handle->schema_type", "")]),
    "close-list": close_list,
    "no-upper": lambda: edit("cas_execute.c", "sch_schemas", [(r"LIKE UPPER \('%s'\)", "LIKE '%s'")]),
    "like-to-equal": lambda: edit("cas_execute.c", "sch_schemas", [(
        r"""LIKE UPPER \('%s'\) ESCAPE '%s' ", (\w+),\s*get_backslash_escape_string \(\)\)""",
        lambda m: "= UPPER ('%s') \", " + m.group(1) + ")")]),
    "db-user": lambda: edit("cas_execute.c", "sch_schemas", [
        (r"SELECT schema_name FROM information_schema\.schemata", "SELECT name FROM db_user"),
        (r"AND schema_name LIKE", "AND name LIKE"),
        (r"AND schema_name = ", "AND name = "),
        (r"ORDER BY schema_name", "ORDER BY name")]),
}

try:
    MUTANTS[name]()
except (KeyError, ValueError) as e:
    sys.exit("%s: %s" % (name, e))
print("%s applied" % name)
