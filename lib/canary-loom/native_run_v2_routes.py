"""Closed RunV2 routes for the primary protein removal (lastdb#793, then #803).

Each route admits one reviewed program pair or one offline format activation.
A route stays closed while its accepted source is None. To open it, pin the
full accepted main commit on its own line below. Every other value derives
from that commit, the reviewed source record, and GitHub metadata.
"""

from native_upgrade_common import require

FORMAT4 = b"format=4\nhome=disk-run\ncas=disk-cas\nranges=typed-v1\n"
FORMAT6 = b"format=6\nhome=disk-run\ncas=disk-cas\nranges=typed-v1\nalternate-keys=v2\n"
# The V2 backup run profile version of each native marker (lastdb run_codec.rs).
RUN_PROFILE = {FORMAT4: 2, FORMAT6: 4}

A1C406F5 = "a1c406f5d1dbfdd99b826be2e4854c025993a90b"
A1C406F5_PROGRAMS = {
    "lastdb": "e862af20bf73a77b38c4025820834b29ed15c62fd216b4a18d1da4f46b1d5db4",
    "lastdbd": "13fa813185ffb186cf085091968805af0e55e1988e83e7b1d398f6e2ca6b6fa4",
}

# PIN: the accepted lastdb main commit that contains #793 and not #803.
C793 = None
# PIN: the accepted lastdb main commit that contains #803.
C803 = None

APPROVAL = "lastdb.run-v2-maintenance-approval.v5"
EVIDENCE = "lastdb.run-v2-maintenance-evidence.v5"
PROTOCOL = "15"
P1 = "run-v2-a1c406f5-to-c793-format4-v1"
P1B = "run-v2-c793-format6-activation-v1"
P2 = "run-v2-c793-to-c803-format6-v1"

# baseline_programs None: the approval names the installed pair, and the gate
# binds it to a verified Mini artifact of the baseline source (P2), or to the
# verified candidate pair itself (P1b, where the program pair does not change).
ROUTES = {
    P1: {"kind": "program", "baseline": A1C406F5, "baseline_programs": A1C406F5_PROGRAMS,
         "source": C793, "marker": FORMAT4, "after": FORMAT4, "development": P1},
    P1B: {"kind": "activation", "baseline": C793, "baseline_programs": None,
          "source": C793, "marker": FORMAT4, "after": FORMAT6, "development": P1},
    P2: {"kind": "program", "baseline": C793, "baseline_programs": None,
         "source": C803, "marker": FORMAT6, "after": FORMAT6, "development": P2},
}


def known(profile):
    return profile in ROUTES


def route(value):
    """Return the open route for an approval, evidence, or plan record."""
    profile = value.get("profile")
    require(profile in ROUTES, "The RunV2 route is not a closed protein-removal route")
    selected = dict(ROUTES[profile], profile=profile)
    require(selected["source"] is not None and selected["baseline"] is not None,
            "The RunV2 route is closed until its accepted lastdb main commit is pinned")
    if value.get("schema") is not None and value["schema"].startswith("lastdb.run-v2-maintenance-"):
        require(value["schema"] in (APPROVAL, EVIDENCE), "The RunV2 route needs its exact v5 schema")
    return selected


def development(selected):
    """The route whose exact pair the main Mac DEV operation qualifies."""
    return route({"profile": selected["development"]})


def activation(approval):
    return known(approval.get("profile")) and route(approval)["kind"] == "activation"


def markers(approval):
    """Native markers that the stable home check admits for this approval."""
    if not known(approval.get("profile")):
        return (FORMAT4,)
    selected = route(approval)
    return tuple(dict.fromkeys((selected["marker"], selected["after"])))


def stopped_marker(approval):
    """The native marker during the strict stop and the final stopped backup."""
    return route(approval)["marker"] if known(approval.get("profile")) else FORMAT4


def run_version(approval):
    """The V2 backup run profile of every recovery point that this route accepts."""
    return RUN_PROFILE[stopped_marker(approval)]
