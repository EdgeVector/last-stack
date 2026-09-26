#!/usr/bin/env python3
"""Small PlistBuddy compatibility tool for the disposable Linux CI container."""

import plistlib
import shlex
import sys


def die(message):
    print(f"PlistBuddy compatibility error: {message}", file=sys.stderr)
    raise SystemExit(1)


def path_parts(raw):
    if not raw.startswith(":"):
        die(f"path must start with a colon: {raw}")
    return [part for part in raw.split(":") if part]


def at_path(root, parts):
    value = root
    for part in parts:
        value = value[int(part)] if isinstance(value, list) else value[part]
    return value


def parent(root, parts):
    if not parts:
        die("root updates are not supported")
    return at_path(root, parts[:-1]), parts[-1]


def value_for(kind, raw):
    if kind == "dict":
        return {}
    if kind == "array":
        return []
    if kind == "string":
        return raw
    if kind == "integer":
        return int(raw)
    if kind == "bool":
        return raw.lower() in {"true", "yes", "1"}
    die(f"unsupported value type: {kind}")


def print_value(value):
    if isinstance(value, dict):
        for key, item in value.items():
            print(f"{key} = {item}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            print(f"{index} = {item}")
    elif isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)


def main(argv):
    if len(argv) != 4 or argv[1] != "-c":
        die("usage: PlistBuddy -c '<command>' <plist>")
    words = shlex.split(argv[2])
    if not words:
        die("command is empty")
    try:
        with open(argv[3], "rb") as source:
            root = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        die(str(error))
    verb = words[0]
    if verb == "Print" and len(words) == 2:
        try:
            print_value(at_path(root, path_parts(words[1])))
        except (KeyError, IndexError, ValueError):
            raise SystemExit(1)
        return
    if verb == "Add" and len(words) >= 3:
        container, key = parent(root, path_parts(words[1]))
        value = value_for(words[2], " ".join(words[3:]))
        if isinstance(container, list):
            container.insert(int(key), value)
        elif key not in container:
            container[key] = value
        else:
            die(f"key already exists: {key}")
    elif verb == "Set" and len(words) >= 3:
        container, key = parent(root, path_parts(words[1]))
        if isinstance(container, list):
            container[int(key)] = " ".join(words[2:])
        else:
            container[key] = " ".join(words[2:])
    elif verb == "Delete" and len(words) == 2:
        container, key = parent(root, path_parts(words[1]))
        try:
            if isinstance(container, list):
                del container[int(key)]
            else:
                del container[key]
        except (KeyError, IndexError, ValueError):
            die(f"Delete: entry does not exist: {words[1]}")
    else:
        die(f"unsupported command: {argv[2]}")
    with open(argv[3], "wb") as destination:
        plistlib.dump(root, destination, sort_keys=False)


if __name__ == "__main__":
    main(sys.argv)
