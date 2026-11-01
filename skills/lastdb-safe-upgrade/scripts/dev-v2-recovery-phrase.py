#!/usr/bin/env python3
"""Print the BIP39 recovery phrase of one 32-byte identity seed to a pipe.

A format 7 V2 restore reads the account recovery phrase on stdin. LastDB
derives that phrase from the identity seed with BIP39 (256-bit entropy, 24
words), the same encoding as `lastdb cloud backup-v2 init`. The CLI has no
command that prints the phrase of an existing seed, so the DEV restore proof
derives it here and pipes it straight into `backup-v2 restore`.

The phrase is the account root. This script refuses a terminal on stdout and
writes nothing to disk. The word list is pinned by its published SHA-256
(the same pin as lastdb scripts/cloud_backup/baseline_data.py).
"""

import argparse
import hashlib
import os
from pathlib import Path
import stat
import sys

WORDS_SHA256 = "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"


def fail(code):
    print("dev-v2-recovery-phrase: %s" % code, file=sys.stderr)
    raise SystemExit(1)


def words():
    path = Path(__file__).resolve().with_name("bip39-english.txt")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != WORDS_SHA256:
        fail("word_list_digest")
    values = raw.decode("ascii").split("\n")[:-1]
    if len(values) != 2048 or len(set(values)) != 2048:
        fail("word_list_shape")
    return values


def seed(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size != 32):
            fail("identity_seed_file")
        value = stream.read(33)
    if len(value) != 32:
        fail("identity_seed_size")
    return value


def phrase(entropy, values):
    bits = (int.from_bytes(entropy, "big") << 8) | hashlib.sha256(entropy).digest()[0]
    return " ".join(values[(bits >> (11 * (23 - n))) & 0x7FF] for n in range(24))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed-file", required=True, type=Path)
    args = parser.parse_args()
    if os.isatty(sys.stdout.fileno()):
        fail("stdout_is_a_terminal")
    sys.stdout.write(phrase(seed(args.seed_file), words()) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
