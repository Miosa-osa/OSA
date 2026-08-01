import type { Provider } from "./types";

export type ValidationResult =
  | { ok: true }
  | {
      ok: false;
      code: "invalid_key" | "rate_limited" | "network_error" | "timeout";
      message: string;
    };

export async function validateApiKey(
  provider: Provider,
  key: string,
): Promise<ValidationResult> {
  const configs: Record<
    string,
    {
      url: string;
      method: string;
      headers: Record<string, string>;
      body?: string;
    }
  > = {
    anthropic: {
      url: "https://api.anthropic.com/v1/messages",
      method: "POST",
      headers: {
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      // `claude-haiku-20240307` was not a real model id (the retired one was
      // `claude-3-haiku-20240307`, sunset 2026-04-20). Anthropic answered a
      // perfectly valid key with a 404, which this function classifies as
      // `network_error` — so onboarding could never report "verified" for
      // ANY Anthropic key. Probe the cheapest CURRENT model instead; keep it
      // in sync with `Providers.AnthropicModels`.
      body: JSON.stringify({
        model: "claude-haiku-4-5",
        max_tokens: 1,
        messages: [{ role: "user", content: "hi" }],
      }),
    },
    openai: {
      url: "https://api.openai.com/v1/models",
      method: "GET",
      headers: { Authorization: `Bearer ${key}` },
    },
    groq: {
      url: "https://api.groq.com/openai/v1/models",
      method: "GET",
      headers: { Authorization: `Bearer ${key}` },
    },
  };

  const config = configs[provider];
  if (!config) return { ok: true }; // local providers skip validation

  try {
    const res = await fetch(config.url, {
      method: config.method,
      headers: config.headers,
      body: config.body,
      signal: AbortSignal.timeout(5000),
    });

    if (res.ok) return { ok: true };
    if (res.status === 401)
      return {
        ok: false,
        code: "invalid_key",
        message:
          "Invalid API key. Check for extra spaces or missing characters.",
      };
    if (res.status === 429)
      return {
        ok: false,
        code: "rate_limited",
        message: "Rate limit hit. Your key is valid — you can continue anyway.",
      };
    return {
      ok: false,
      code: "network_error",
      message: `Unexpected response (${res.status}). Try continuing anyway.`,
    };
  } catch (e) {
    if (e instanceof DOMException && e.name === "TimeoutError") {
      return {
        ok: false,
        code: "timeout",
        message: "Request timed out. Check your connection or continue anyway.",
      };
    }
    return {
      ok: false,
      code: "network_error",
      message: "Can't reach the provider. Check your internet connection.",
    };
  }
}
