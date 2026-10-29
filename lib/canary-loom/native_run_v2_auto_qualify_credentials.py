"""Keep fresh ordinary DEV credentials private and bind only their file hashes."""
import os
from pathlib import Path
import re
import stat

from mnemonic import Mnemonic

from native_run_v2_auto_qualify_io import (_open, _stable, read, reference, require, secret)


def _home(path):
    home = Path(path)
    require(home.is_absolute() and home.resolve() == home, "exact_credential_home")
    info = home.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700
            and not (home / "data").exists() and not (home / "current-session.json").exists(),
            "private_credentials_only_home")
    return home


def binding(home, from_home, api_key_ref=None, phrase_ref=None):
    home = _home(home)
    if not from_home:
        for locator in (api_key_ref, phrase_ref):
            require(isinstance(locator, str) and re.fullmatch(
                r"lastsecrets://[A-Za-z0-9][A-Za-z0-9._-]{0,127}", locator), "secret_locator_only")
        return {"mode": "lastsecrets", "api_key_ref": api_key_ref, "phrase_ref": phrase_ref}
    require(api_key_ref is None and phrase_ref is None, "one_credential_input_mode")
    paths = {"identity": home / "identity.key", "credentials": home / "cloud_sync.json.paused"}
    for name, path in paths.items():
        _, descriptor, info = _open(path, 32 if name == "identity" else 65536, private=True)
        os.close(descriptor)
        require(name != "identity" or info.st_size == 32, "identity_seed_length")
    return {"mode": "private-home", "files": {name: reference(path) for name, path in paths.items()}}


def load(home, selected, endpoint):
    home = _home(home)
    if selected["mode"] == "lastsecrets":
        require(selected == binding(home, False, selected["api_key_ref"], selected["phrase_ref"]),
                "frozen_secret_locators")
        return secret(selected["api_key_ref"]), secret(selected["phrase_ref"])
    require(selected["mode"] == "private-home" and selected == binding(home, True),
            "frozen_private_credential_files")
    credentials = read(home / "cloud_sync.json.paused", 65536)
    require(set(credentials) == {"api_url", "api_key"} and credentials["api_url"] == endpoint
            and isinstance(credentials["api_key"], str), "compiled_dev_credential_endpoint")
    api_key = credentials["api_key"].encode("utf-8")
    require(0 < len(api_key) <= 4096 and b"\0" not in api_key, "bounded_private_api_key")
    path, descriptor, before = _open(home / "identity.key", 32, private=True)
    with os.fdopen(descriptor, "rb") as stream:
        seed = stream.read(33)
        require(len(seed) == 32, "identity_seed_length")
        _stable(path, stream, before)
    phrase = Mnemonic("english").to_mnemonic(seed).encode("utf-8")
    del credentials, seed
    require(selected == binding(home, True), "unchanged_private_credential_files")
    return api_key, phrase
