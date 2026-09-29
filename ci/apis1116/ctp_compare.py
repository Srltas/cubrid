#!/usr/bin/env python3
"""ctp_compare.py <before.xml> <after.xml> <diff.txt>

Compares two CTP JDBC runs by failing case (<test file>::<method>) and prints one check per line
as check|expected|actual|true-or-false. The full lists go to diff.txt.

The committed CTP jar collects the lambda$ methods javac generates for assertThrows as cases and
fails every one of them ("No tests found matching Method lambda$..."); they are not tests, so they
are counted apart and left out of the comparison.
"""
import os
import sys
import xml.etree.ElementTree as ET

MIN_CASES = 2000


def load(path):
    cases, failed, synthetic = set(), set(), 0
    if not os.path.exists(path):
        return cases, failed, synthetic
    for tc in ET.parse(path).getroot().iter("testcase"):
        # CTP writes "<path of the test file> => <method>()" into file, classname and name alike
        source, _, method = (tc.get("file") or tc.get("name") or "?").partition(" => ")
        if method.startswith("lambda$"):
            synthetic += 1
            continue
        case = "%s::%s" % (source.split("/src/", 1)[-1], method)
        cases.add(case)
        if tc.find("failure") is not None or tc.find("error") is not None:
            failed.add(case)
    return cases, failed, synthetic


before_xml, after_xml, diff_txt = sys.argv[1:4]
before_cases, before_failed, before_synthetic = load(before_xml)
after_cases, after_failed, after_synthetic = load(after_xml)
new = sorted(after_failed - before_failed)
gone = sorted(before_failed - after_failed)

with open(diff_txt, "w") as f:
    f.write("before: %d cases, %d failed\nafter: %d cases, %d failed\n\n" % (
        len(before_cases), len(before_failed), len(after_cases), len(after_failed)))
    f.write("new failures (%d):\n%s\n\n" % (len(new), "\n".join(new)))
    f.write("no longer failing (%d):\n%s\n\n" % (len(gone), "\n".join(gone)))
    f.write("failing in both (%d):\n%s\n" % (len(before_failed & after_failed), "\n".join(sorted(before_failed & after_failed))))

rows = [
    ("CTP before: cases run", ">= %d" % MIN_CASES, str(len(before_cases)), len(before_cases) >= MIN_CASES),
    ("CTP after: cases run", ">= %d" % MIN_CASES, str(len(after_cases)), len(after_cases) >= MIN_CASES),
    ("CTP: failures new with the patch", "0", "%d%s" % (len(new), ": " + ", ".join(new[:5]) if new else ""), not new),
    ("CTP: failed cases before / after", "-", "%d / %d" % (len(before_failed), len(after_failed)), True),
    ("CTP: failures gone with the patch", "-", "%d%s" % (len(gone), ": " + ", ".join(gone[:5]) if gone else ""), True),
    ("CTP: lambda$ entries left out before / after", "-", "%d / %d" % (before_synthetic, after_synthetic), True),
]
for check, expected, actual, ok in rows:
    print("%s|%s|%s|%s" % (check, expected, actual, "true" if ok else "false"))
