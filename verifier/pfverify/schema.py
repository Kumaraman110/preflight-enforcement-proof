"""Bounded JSON Schema validator (stdlib only, zero pip dependencies).

We deliberately do NOT depend on the `jsonschema` package: a security-critical
verifier must be fully reviewable and reproducible with no external supply chain.
This validator supports EXACTLY the draft-2020-12 keywords our own schemas use —
type, required, properties, additionalProperties, pattern, enum, minLength,
minItems, items. Any schema keyword it does not recognize is a HARD ERROR, so the
validator can never silently under-enforce a constraint it doesn't understand
(fail-closed by construction).

Returns a list of error strings; empty list == valid. It never raises on ordinary
invalid input — malformed data is reported as errors, which the engine treats as a
fail-closed BLOCK.
"""
from __future__ import annotations

import re
from typing import Any, List

SUPPORTED_KEYWORDS = {
    "$schema", "$id", "title", "description",
    "type", "required", "properties", "additionalProperties",
    "pattern", "enum", "minLength", "minItems", "items",
}

_TYPE_CHECKS = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    # bool is a subclass of int in Python; exclude it from number/integer.
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


class SchemaError(Exception):
    """Raised when the SCHEMA itself uses an unsupported keyword — a build-time
    fault in our own schema, surfaced loudly rather than silently ignored."""


def _assert_supported(schema: dict, where: str) -> None:
    for kw in schema.keys():
        if kw not in SUPPORTED_KEYWORDS:
            raise SchemaError(
                f"unsupported schema keyword {kw!r} at {where}; this bounded "
                f"validator only supports {sorted(SUPPORTED_KEYWORDS)}"
            )


def validate(instance: Any, schema: dict, where: str = "$") -> List[str]:
    """Validate `instance` against `schema`. Returns a list of error strings."""
    errors: List[str] = []
    _assert_supported(schema, where)

    # type
    expected = schema.get("type")
    if expected is not None:
        check = _TYPE_CHECKS.get(expected)
        if check is None:
            raise SchemaError(f"unsupported type {expected!r} at {where}")
        if not check(instance):
            errors.append(f"{where}: expected type {expected}, got {_typename(instance)}")
            # If the base type is wrong, further keyword checks are meaningless.
            return errors

    # enum
    if "enum" in schema:
        if instance not in schema["enum"]:
            errors.append(f"{where}: value {instance!r} not in enum {schema['enum']}")

    # string constraints
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{where}: string shorter than minLength {schema['minLength']}")
        if "pattern" in schema:
            if re.search(schema["pattern"], instance) is None:
                errors.append(f"{where}: string does not match pattern {schema['pattern']!r}")

    # array constraints
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{where}: array has fewer than minItems {schema['minItems']}")
        item_schema = schema.get("items")
        if item_schema is not None:
            for i, item in enumerate(instance):
                errors.extend(validate(item, item_schema, f"{where}[{i}]"))

    # object constraints
    if isinstance(instance, dict):
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            if req not in instance:
                errors.append(f"{where}: missing required property {req!r}")
        additional = schema.get("additionalProperties", True)
        for key, val in instance.items():
            if key in props:
                errors.extend(validate(val, props[key], f"{where}.{key}"))
            elif additional is False:
                errors.append(f"{where}: additional property {key!r} not allowed")
            elif isinstance(additional, dict):
                errors.extend(validate(val, additional, f"{where}.{key}"))

    return errors


def _typename(v: Any) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    if isinstance(v, int):
        return "integer"
    if isinstance(v, float):
        return "number"
    return type(v).__name__
