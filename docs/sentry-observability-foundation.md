# Sentry Observability Foundation

The `edge-vector` Sentry org uses one project per major service class so triage
can route errors without guessing from stack traces alone. Public DSNs are still
stored only in LastSecrets, and install surfaces should reference the locator
for their service instead of committing or logging DSN values.

## Project Matrix

| Sentry project | LastSecrets DSN locator | Primary repo routing |
|---|---|---|
| `rust` | `lastsecrets://obs-sentry-dsn-rust` | `EdgeVector/fold` |
| `javascript-react` | `lastsecrets://obs-sentry-dsn-javascript-react` | `EdgeVector/fold` |
| `javascript-react-xq` | `lastsecrets://obs-sentry-dsn-javascript-react-xq` | `EdgeVector/fold` |
| `lastdb-mini` | `lastsecrets://obs-sentry-dsn-lastdb-mini` | `EdgeVector/fold` |
| `exemem-backend` | `lastsecrets://obs-sentry-dsn-exemem-backend` | `EdgeVector/exemem-infra` |
| `agent-cli` | `lastsecrets://obs-sentry-dsn-agent-cli` | `EdgeVector/last-stack` |
| `routines` | `lastsecrets://obs-sentry-dsn-routines` | `EdgeVector/routines` |
| `lastgit` | `lastsecrets://obs-sentry-dsn-lastgit` | `EdgeVector/lastgit` |
| `remote` | `lastsecrets://obs-sentry-dsn-remote` | `EdgeVector/remote` |
| `discovery` | `lastsecrets://obs-sentry-dsn-discovery` | `EdgeVector/discovery` |
| `photos` | `lastsecrets://obs-sentry-dsn-photos` | `EdgeVector/discovery` |

## Runtime Contract

LaunchAgents, deploy wrappers, and local smoke scripts should set these
environment variables when enabling Sentry for a process:

```text
OBS_SENTRY_DSN=lastsecrets://obs-sentry-dsn-<project>
OBS_SENTRY_ENVIRONMENT=<dev|prod|local|ci>
OBS_SENTRY_RELEASE=<repo-or-service>@<version-or-commit>
OBS_SENTRY_SERVICE=<service-name>
```

Resolve `OBS_SENTRY_DSN` at the point of process launch and avoid writing the
raw value to logs, Brain, Kanban, PR descriptions, or source files. Use the
`service`, `environment`, and `release` tags consistently even when multiple
small binaries share a project such as `agent-cli`.

## Bun/TypeScript Helper

Reusable Bun/TypeScript services can initialize Sentry through
`lib/observability/sentry.ts`:

```ts
import { initSentry } from "./lib/observability/sentry";

await initSentry({ service: "routinesd" });
```

The helper is a no-op when `OBS_SENTRY_DSN` is unset. When a DSN is present, the
consuming repo must provide `@sentry/node`; the helper initializes the SDK with
`service`, `environment`, and `release` tags, installs process handlers for
uncaught exceptions and unhandled rejections, and redacts common secret-bearing
request headers and event extras before send. Tests can inject `sentryModule` to
avoid network calls.

## Triage Reader

`skills/morning-sync/usage-bugs.sh sentry` reads unresolved issues from every
project above using the read token locator recorded in `signal-sources`. The
script is intentionally read-only; project creation and DSN rotation belong in
Sentry plus LastSecrets, not in the morning reader.
