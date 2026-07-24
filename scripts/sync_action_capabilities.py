#!/usr/bin/env python3
"""Validate and copy the portable MIOSA action identity contract into OSA."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path

CAPABILITY_NAME = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$")
FINGERPRINT = re.compile(r"^sha256:[0-9a-f]{64}$")
FORBIDDEN_POLICY_KEYS = {
    "approval",
    "limits",
    "rate_limit",
    "required_organization_action",
    "risk",
    "scope",
}


def validate(contract: dict[str, object]) -> None:
    capabilities = contract.get("capabilities")
    if not isinstance(capabilities, list):
        raise ValueError("contract must contain a capabilities list")

    aliases: set[str] = set()
    for capability in capabilities:
        if not isinstance(capability, dict):
            raise ValueError("every capability must be an object")
        forbidden = FORBIDDEN_POLICY_KEYS.intersection(capability)
        if forbidden:
            raise ValueError(
                "identity contract contains server-owned policy: "
                + ", ".join(sorted(forbidden))
            )
        name = capability.get("name")
        fingerprint = capability.get("fingerprint")
        if not isinstance(name, str) or not CAPABILITY_NAME.fullmatch(name):
            raise ValueError(f"invalid capability name: {name!r}")
        if not isinstance(fingerprint, str) or not FINGERPRINT.fullmatch(fingerprint):
            raise ValueError(f"invalid capability fingerprint for {name}")
        surfaces = capability.get("surfaces")
        if not isinstance(surfaces, dict):
            raise ValueError(f"capability {name} has no surfaces object")
        osa_aliases = surfaces.get("osa", [])
        if not isinstance(osa_aliases, list) or not all(
            isinstance(alias_name, str) and alias_name for alias_name in osa_aliases
        ):
            raise ValueError(f"capability {name} has invalid OSA aliases")
        duplicate = aliases.intersection(osa_aliases)
        if duplicate:
            raise ValueError(f"duplicate OSA alias: {sorted(duplicate)[0]}")
        aliases.update(osa_aliases)

    if not aliases:
        raise ValueError("contract contains no OSA aliases")


def sync(source: Path, destination: Path) -> None:
    contract = json.loads(source.read_text(encoding="utf-8"))
    validate(contract)
    rendered = json.dumps(contract, indent=2) + "\n"
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        os.chmod(temp_name, 0o644)
        os.replace(temp_name, destination)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("priv/action-capabilities.json"),
    )
    args = parser.parse_args()
    sync(args.source, args.output)


if __name__ == "__main__":
    main()
