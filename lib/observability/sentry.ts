export type SentryInitOptions = {
  service: string;
  dsnEnv?: string;
  environmentEnv?: string;
  releaseEnv?: string;
  enabled?: boolean;
  installProcessHandlers?: boolean;
  env?: Record<string, string | undefined>;
  sentryModule?: SentryModule;
};

export type SentryInitResult =
  | { enabled: false; reason: "disabled" | "missing_dsn" | "invalid_dsn" }
  | { enabled: true; service: string; environment?: string; release?: string };

/**
 * Parse OBS_SENTRY_DSN without calling Sentry.init.
 *
 * Invalid values (empty, lastsecrets:// locators, non-http(s), unparseable)
 * return null so callers disable Sentry instead of letting @sentry/core print
 * `Invalid Sentry Dsn` or panic. Routine/agent shells inherit unresolved
 * locators from routinesd; those must never reach the SDK or stdout.
 */
function parseObsSentryDsn(raw: string): string | null {
  const dsn = raw.trim();
  if (!dsn) return null;

  if (dsn.startsWith("lastsecrets://") || dsn.startsWith("lastsecrets:")) {
    return null;
  }

  if (!/^https?:\/\//i.test(dsn)) {
    return null;
  }

  const DSN_RE =
    /^(?:https?):\/\/(?:[\w.-]+)(?::[\w.-]+)?@((?:\[[:.%\w]+\]|[\w.-]+))(?::\d+)?\/(.+)$/i;
  if (!DSN_RE.test(dsn)) {
    return null;
  }

  return dsn;
}

function debugObsEnabled(env: Record<string, string | undefined>): boolean {
  const flag = env.OBS_SENTRY_DEBUG ?? env.OBS_DEBUG ?? "";
  return flag === "1" || flag.toLowerCase() === "true";
}

function warnInvalidDsn(
  dsnEnv: string,
  raw: string,
  env: Record<string, string | undefined>,
): void {
  // Default path is silent. A lastsecrets locator is expected in routine
  // shells; printing it on every CLI is what poisons `2>&1 | jq` pipelines.
  if (!debugObsEnabled(env)) return;
  const hint =
    raw.startsWith("lastsecrets://") || raw.startsWith("lastsecrets:")
      ? "lastsecrets locator (not a Sentry DSN)"
      : "not a valid https Sentry DSN";
  process.stderr.write(
    `observability: ${dsnEnv} is ${hint}; Sentry disabled. Resolve the secret in a process wrapper or unset the var.\n`,
  );
}

export type SentryModule = {
  init(options: {
    dsn: string;
    environment?: string;
    release?: string;
    tracesSampleRate?: number;
    beforeSend?: (event: SentryEvent) => SentryEvent | null;
    initialScope?: {
      tags?: Record<string, string>;
    };
  }): void;
  captureException(error: unknown, context?: { tags?: Record<string, string> }): void;
  flush?(timeoutMs?: number): Promise<boolean>;
};

type SentryEvent = {
  request?: {
    cookies?: unknown;
    headers?: Record<string, unknown>;
  };
  extra?: Record<string, unknown>;
  tags?: Record<string, string>;
};

let installed = false;

export async function initSentry(options: SentryInitOptions): Promise<SentryInitResult> {
  const env = options.env ?? process.env;
  const dsnEnv = options.dsnEnv ?? "OBS_SENTRY_DSN";
  const enabled = options.enabled ?? true;

  if (!enabled) {
    return { enabled: false, reason: "disabled" };
  }

  const dsnRaw = env[dsnEnv]?.trim();
  if (!dsnRaw) {
    return { enabled: false, reason: "missing_dsn" };
  }

  const dsn = parseObsSentryDsn(dsnRaw);
  if (!dsn) {
    warnInvalidDsn(dsnEnv, dsnRaw, env);
    return { enabled: false, reason: "invalid_dsn" };
  }

  const sentry = options.sentryModule ?? (await loadSentryModule());
  const environment = env[options.environmentEnv ?? "OBS_SENTRY_ENVIRONMENT"];
  const release = env[options.releaseEnv ?? "OBS_SENTRY_RELEASE"];
  const service = options.service;

  sentry.init({
    dsn,
    environment,
    release,
    tracesSampleRate: 0,
    beforeSend: redactEvent,
    initialScope: {
      tags: {
        service,
      },
    },
  });

  if ((options.installProcessHandlers ?? true) && !installed) {
    installed = true;
    installProcessHandlers(sentry, service);
  }

  return {
    enabled: true,
    service,
    environment,
    release,
  };
}

async function loadSentryModule(): Promise<SentryModule> {
  try {
    return (await import("@sentry/node")) as SentryModule;
  } catch (error) {
    throw new Error(
      "OBS_SENTRY_DSN is set but @sentry/node is not installed; add it to the consuming Bun/TS repo",
      { cause: error },
    );
  }
}

function installProcessHandlers(sentry: SentryModule, service: string): void {
  process.on("uncaughtException", (error) => {
    sentry.captureException(error, { tags: { service, unhandled: "uncaughtException" } });
    void sentry.flush?.(2000).finally(() => {
      process.exitCode = 1;
    });
  });

  process.on("unhandledRejection", (reason) => {
    sentry.captureException(reason, { tags: { service, unhandled: "unhandledRejection" } });
    void sentry.flush?.(2000);
  });
}

function redactEvent(event: SentryEvent): SentryEvent {
  if (event.request?.cookies) {
    event.request.cookies = "[redacted]";
  }

  if (event.request?.headers) {
    for (const key of Object.keys(event.request.headers)) {
      if (/authorization|cookie|token|key|secret/i.test(key)) {
        event.request.headers[key] = "[redacted]";
      }
    }
  }

  if (event.extra) {
    for (const key of Object.keys(event.extra)) {
      if (/password|token|secret|dsn|key/i.test(key)) {
        event.extra[key] = "[redacted]";
      }
    }
  }

  return event;
}
