# HostTrack retired

LastDB's signed app registry is the installation and update authority. Use
`lastdb app install`, `app upgrade`, `app status --check`, and `app rollback`.
The installer owns source versions, current/previous, command links, probes,
consent and the independent updater. Old artifact controllers and stores are
removed after app, service and connector migration is proved.

Last Stack remains available through `~/.last-stack` compatibility code links to
`~/.local/share/lastdb-apps/last-stack/current/source`. State and evidence remain
under `~/.local/state/last-stack`. The canonical LastDB program pair stays under
`~/.lastdb/current` and uses the separate safe-upgrade workflow.

Historical factory receipts retain their original authority paths as evidence.
They cannot authorize an artifact install or be treated as registry receipts.
The finite October artifact-bound repair protocol refuses new candidate/install
operations until its authority is reviewed for the registry model.
