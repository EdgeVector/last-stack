---
name: app-safe-upgrade
description: Install, upgrade, inspect or roll back an app through LastDB's signed app registry.
---

# App upgrades

Use the installed canonical LastDB CLI. Read `lastdb app status <app> --check --json`
and the installed receipt before changing an app. A private index is a LastSecrets
locator; resolve it only at use and never print or persist its raw URL.

Run `lastdb app upgrade <app>` for an installed app, or `lastdb app upgrade --all`
for the fleet. The installer verifies the exact node interface, registry and
publisher signatures, pinned source commit, install instructions and command
links. Preparation and functional probes run before activation. App hooks handle
their own existing services. Failed activation restores the prior version.

When install instructions, schema uses or publisher identity change, review the
instructions before accepting consent. Never bypass a failed non-test gate.
Use `lastdb app rollback <app>` for a retained compatible previous version; never
repoint command links or `current` by hand. Keep three installed versions.

The native updater polls next every minute and stable hourly. It follows signed
published source, rather than an arbitrary repository main branch. CI builds,
security checks and real operational proof remain required before publication.

Respect host policy. When Kanban and Situations are off, move their code only
with `--inactive`, do not invoke either app, and do not initialize their schemas.
Carry `LAST_STACK_APPS_OFF=1` into this host's activation and updater environment.

The LastDB program pair is separate. Every primary LastDB version change uses
the `lastdb-safe-upgrade` skill and its backup, restore, clean-stop and health
gates. This app workflow never upgrades or restarts the primary database.
