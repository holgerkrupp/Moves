#!/usr/bin/env python3
"""Check direct CloudKit record usage against the infrastructure manifest."""

from __future__ import annotations

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "Configuration" / "CloudKitInfrastructureSchema.json"
SWIFT_ROOTS = [ROOT / "Moves", ROOT / "Mac"]


def fail(message: str) -> None:
    print(f"CloudKit schema preflight failed: {message}", file=sys.stderr)
    raise SystemExit(1)


manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
declared = {item["name"]: item for item in manifest["recordTypes"]}
if len(declared) != len(manifest["recordTypes"]):
    fail("record type names in the manifest must be unique")

swift_files = [path for root in SWIFT_ROOTS for path in root.rglob("*.swift")]
source = "\n".join(path.read_text(encoding="utf-8") for path in swift_files)
constants = dict(
    re.findall(r"static\s+let\s+(\w*RecordType)\s*=\s*\"([^\"]+)\"", source)
)

record_type_expressions = re.findall(
    r"CKRecord\s*\(\s*recordType\s*:\s*([^,\n\)]+)", source, flags=re.MULTILINE
)
referenced: set[str] = set()
unresolved: list[str] = []
for expression in record_type_expressions:
    expression = expression.strip()
    literal = re.fullmatch(r'"([^\"]+)"', expression)
    if literal:
        referenced.add(literal.group(1))
        continue
    constant_name = expression.rsplit(".", 1)[-1]
    if constant_name in constants:
        referenced.add(constants[constant_name])
    else:
        unresolved.append(expression)

if unresolved:
    fail("dynamic/unresolved CKRecord recordType expressions: " + ", ".join(sorted(unresolved)))
undeclared = referenced - declared.keys()
if undeclared:
    fail("direct CKRecord types missing from the manifest: " + ", ".join(sorted(undeclared)))
unused = declared.keys() - referenced
if unused:
    fail("manifest record types with no direct CKRecord usage: " + ", ".join(sorted(unused)))

lease_source = (ROOT / "Moves" / "CrossDeviceWorkCoordinator.swift").read_text(encoding="utf-8")
lease_fields = set(re.findall(r'record\["([^\"]+)"\]', lease_source))
manifest_fields = set(declared["MovesWorkLease"]["fields"])
if lease_fields != manifest_fields:
    missing = sorted(lease_fields - manifest_fields)
    stale = sorted(manifest_fields - lease_fields)
    fail(f"MovesWorkLease field mismatch; missing={missing}, stale={stale}")

if manifest["containerIdentifier"] != "iCloud.de.holgerkrupp.Moves":
    fail("unexpected CloudKit container identifier")

print(
    "CloudKit schema preflight passed: "
    + ", ".join(f"{name} ({len(item['fields'])} fields)" for name, item in sorted(declared.items()))
)
