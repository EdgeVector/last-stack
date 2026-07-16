import { describe, expect, test } from "bun:test";
import { initSentry, type SentryModule } from "../../lib/observability/sentry";

function mockSentry() {
  const calls: unknown[] = [];
  const module: SentryModule = {
    init(options) {
      calls.push(options);
    },
    captureException() {},
    async flush() {
      return true;
    },
  };
  return { module, calls };
}

describe("initSentry", () => {
  test("no-ops when the DSN env var is unset", async () => {
    const sentry = mockSentry();

    const result = await initSentry({
      service: "routine-runner",
      env: {},
      sentryModule: sentry.module,
      installProcessHandlers: false,
    });

    expect(result).toEqual({ enabled: false, reason: "missing_dsn" });
    expect(sentry.calls).toHaveLength(0);
  });

  test("initializes Sentry with service, release, environment, and redaction", async () => {
    const sentry = mockSentry();

    const result = await initSentry({
      service: "routine-runner",
      env: {
        OBS_SENTRY_DSN: "https://public@example.invalid/1",
        OBS_SENTRY_ENVIRONMENT: "test",
        OBS_SENTRY_RELEASE: "routine-runner@abc123",
      },
      sentryModule: sentry.module,
      installProcessHandlers: false,
    });

    expect(result).toEqual({
      enabled: true,
      service: "routine-runner",
      environment: "test",
      release: "routine-runner@abc123",
    });
    expect(sentry.calls).toHaveLength(1);

    const [options] = sentry.calls as Array<{
      dsn: string;
      environment: string;
      release: string;
      initialScope: { tags: Record<string, string> };
      beforeSend: (event: {
        request: { cookies: string; headers: Record<string, string> };
        extra: Record<string, string>;
      }) => unknown;
    }>;

    expect(options.dsn).toBe("https://public@example.invalid/1");
    expect(options.initialScope.tags.service).toBe("routine-runner");

    const redacted = options.beforeSend({
      request: {
        cookies: "session=secret",
        headers: {
          Authorization: "Bearer secret",
          "X-Api-Key": "secret",
          Accept: "application/json",
        },
      },
      extra: {
        token: "secret",
        safe: "value",
      },
    }) as {
      request: { cookies: string; headers: Record<string, string> };
      extra: Record<string, string>;
    };

    expect(redacted.request.cookies).toBe("[redacted]");
    expect(redacted.request.headers.Authorization).toBe("[redacted]");
    expect(redacted.request.headers["X-Api-Key"]).toBe("[redacted]");
    expect(redacted.request.headers.Accept).toBe("application/json");
    expect(redacted.extra.token).toBe("[redacted]");
    expect(redacted.extra.safe).toBe("value");
  });
});
