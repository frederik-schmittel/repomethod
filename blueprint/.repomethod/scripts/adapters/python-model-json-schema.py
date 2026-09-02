#!/usr/bin/env python3
"""Emit a canonical RepoMethod contract shape from a Python model."""
import argparse
import importlib
import json
import sys


def fail(message: str) -> None:
    print(f"python adapter: {message}", file=sys.stderr)
    raise SystemExit(1)


def resolve_ref(schema, root):
    while isinstance(schema, dict) and set(schema) == {"$ref"}:
        ref = schema["$ref"]
        if not isinstance(ref, str) or not ref.startswith("#/$defs/"):
            fail(f"unsupported schema reference: {ref!r}")
        key = ref[len("#/$defs/"):]
        try:
            schema = root["$defs"][key]
        except (KeyError, TypeError):
            fail(f"unresolved schema reference: {ref}")
    return schema


def enum_values(schema, root):
    schema = resolve_ref(schema, root)
    if not isinstance(schema, dict):
        return None
    if "enum" in schema:
        values = schema["enum"]
        if not isinstance(values, list):
            fail("model_json_schema() returned a non-array enum")
        return values
    choices = schema.get("anyOf") or schema.get("oneOf")
    if isinstance(choices, list):
        enum_sets = []
        for choice in choices:
            resolved = resolve_ref(choice, root)
            if isinstance(resolved, dict) and isinstance(resolved.get("enum"), list):
                enum_sets.extend(resolved["enum"])
        if enum_sets:
            return enum_sets
    return None


def sort_json_values(values):
    return sorted(values, key=lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--type", required=True, dest="type_name")
    args = parser.parse_args()

    try:
        module = importlib.import_module(args.module)
    except Exception as exc:
        fail(f"cannot import module {args.module!r}: {exc}")
    try:
        model = getattr(module, args.model)
    except AttributeError:
        fail(f"model {args.model!r} not found in module {args.module!r}")
    method = getattr(model, "model_json_schema", None)
    if not callable(method):
        fail(f"model {args.model!r} has no callable model_json_schema()")
    try:
        schema = method()
    except Exception as exc:
        fail(f"model_json_schema() failed for {args.model!r}: {exc}")
    if not isinstance(schema, dict):
        fail("model_json_schema() did not return an object")
    properties = schema.get("properties")
    if not isinstance(properties, dict):
        fail("model_json_schema() has no object properties")
    required = schema.get("required", [])
    if not isinstance(required, list) or not all(isinstance(item, str) for item in required):
        fail("model_json_schema() has an invalid required array")

    enums = {}
    for field, field_schema in properties.items():
        values = enum_values(field_schema, schema)
        if values is not None:
            enums[field] = sort_json_values(values)

    output = {
        "version": 1,
        "type": args.type_name,
        "fields": sorted(properties),
        "required": sorted(required),
        "enums": {key: enums[key] for key in sorted(enums)},
    }
    json.dump(output, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
