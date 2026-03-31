// src/lib/api/sse.ts
// fetch-based SSE client.
// Uses fetch (not EventSource) for POST support and Authorization header control.
//
// Backend flow:
//   1. GET  /api/v1/sessions/:id/stream   → opens SSE connection
//   2. POST /api/v1/sessions/:id/message  → sends a message (async)
//   3. Stream events arrive on the GET connection

import type { StreamEvent } from "./types";
import { getToken } from "./client";

// ── OS Notifications ─────────────────────────────────────────────────────────

async function maybeNotify(event: StreamEvent): Promise<void> {
  if (typeof document === "undefined" || document.hasFocus()) return;

  try {
    const { isPermissionGranted, requestPermission, sendNotification } =
      await import("@tauri-apps/plugin-notification");

    let permitted = await isPermissionGranted();
    if (!permitted) {
      const permission = await requestPermission();
      permitted = permission === "granted";
    }
    if (!permitted) return;

    if (event.type === "done") {
      await sendNotification({
        title: "OSA Agent",
        body: "Task completed",
      });
    }
  } catch {
    // Not in Tauri environment or notification plugin not available
  }
}

const BASE_URL = "http://127.0.0.1:9089";
const API_PREFIX = "/api/v1";

// ── Back-off Constants ────────────────────────────────────────────────────────

const INITIAL_DELAY_MS = 1_000;
const MAX_DELAY_MS = 30_000;
const BACKOFF_FACTOR = 2;

// ── Typed Callbacks ───────────────────────────────────────────────────────────

export interface SSECallbacks {
  onEvent: (event: StreamEvent) => void;
  onConnect?: () => void;
  onDisconnect?: () => void;
  onError?: (error: Error) => void;
  onDone?: () => void;
}

export interface StreamController {
  abort: () => void;
}

// ── SSE Line Parser ───────────────────────────────────────────────────────────

/**
 * Parse a raw SSE message block (delimited by \n\n) into typed StreamEvents.
 * Handles the `event:` + `data:` format from the backend.
 * Returns null for keep-alive or comment-only blocks.
 */
function parseSSEBlock(block: string): StreamEvent | null {
  const lines = block.split("\n");
  let eventType = "";
  let data = "";

  for (const line of lines) {
    if (line.startsWith(":")) continue; // comment / keepalive
    if (line.startsWith("event: ")) {
      eventType = line.slice("event: ".length).trim();
    } else if (line.startsWith("data: ")) {
      data = line.slice("data: ".length).trim();
    }
  }

  if (!data || data === "[DONE]") return null;

  try {
    const parsed = JSON.parse(data);
    // If the backend sends an event type field, use it; otherwise trust the JSON's `type`
    // The SSE `event:` line carries the unwrapped sub-type (e.g. "streaming_token")
    // but the JSON data still has `type: "system_event"`. Override with the SSE event type.
    if (eventType && (parsed.type === "system_event" || !parsed.type)) {
      parsed.type = eventType;
    }
    return parsed as StreamEvent;
  } catch {
    // Not JSON — might be a plain text token delta
    if (eventType === "streaming_token" || eventType === "token") {
      return { type: "streaming_token", delta: data } as StreamEvent;
    }
    return null;
  }
}

// ── Stream Reader ─────────────────────────────────────────────────────────────

async function consumeStream(
  response: Response,
  callbacks: SSECallbacks,
  signal: AbortSignal,
): Promise<void> {
  if (!response.body) throw new Error("Response body is null");

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  callbacks.onConnect?.();

  try {
    while (true) {
      if (signal.aborted) break;

      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });

      // SSE messages are delimited by double newlines
      const blocks = buffer.split("\n\n");
      // Keep the last (potentially incomplete) block in the buffer
      buffer = blocks.pop() ?? "";

      for (const block of blocks) {
        if (!block.trim()) continue;

        const event = parseSSEBlock(block);
        if (!event) continue;

        callbacks.onEvent(event);
        maybeNotify(event).catch(() => undefined);

        if (event.type === "done") {
          callbacks.onDone?.();
          return;
        }
        if (event.type === "error") {
          callbacks.onError?.(
            new Error(
              (event as { message?: string }).message ?? "Stream error",
            ),
          );
          return;
        }
      }
    }
  } finally {
    reader.cancel().catch(() => undefined);
    callbacks.onDisconnect?.();
  }
}

// ── Chat Message Stream ───────────────────────────────────────────────────────

export interface ChatStreamOptions extends SSECallbacks {
  sessionId: string;
  content: string;
  model?: string;
}

/**
 * Send a chat message and stream the response.
 *
 * Backend flow:
 *   1. Open GET SSE stream on /sessions/:id/stream
 *   2. POST message to /sessions/:id/message
 *   3. Response tokens arrive on the SSE connection
 *
 * Returns a controller with abort() for cancellation.
 */
export function streamMessage(options: ChatStreamOptions): StreamController {
  const controller = new AbortController();
  const { signal } = controller;

  (async () => {
    const token = getToken();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
      "Cache-Control": "no-cache",
      "X-Accel-Buffering": "no",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;

    try {
      // Step 1: Open SSE stream (GET)
      const streamResponse = await fetch(
        `${BASE_URL}${API_PREFIX}/sessions/${options.sessionId}/stream`,
        { headers, signal },
      );

      if (!streamResponse.ok) {
        const body = await streamResponse.text().catch(() => "");
        throw new Error(`Stream HTTP ${streamResponse.status}: ${body}`);
      }

      // Step 2: POST the message (don't await the stream consumption first)
      const msgHeaders: Record<string, string> = {
        "Content-Type": "application/json",
      };
      if (token) msgHeaders["Authorization"] = `Bearer ${token}`;

      // Fire message POST in parallel with stream consumption
      const messagePromise = fetch(
        `${BASE_URL}${API_PREFIX}/sessions/${options.sessionId}/message`,
        {
          method: "POST",
          headers: msgHeaders,
          body: JSON.stringify({
            message: options.content,
            model: options.model,
          }),
          signal,
        },
      ).then(async (res) => {
        if (!res.ok) {
          const body = await res.text().catch(() => "");
          throw new Error(`Message HTTP ${res.status}: ${body}`);
        }
      });

      // Step 3: Consume stream events
      // The stream will receive events from the message being processed
      await Promise.all([
        consumeStream(streamResponse, options, signal),
        messagePromise,
      ]);
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      options.onError?.(error as Error);
    }
  })();

  return { abort: () => controller.abort() };
}

// ── Agent Event Stream (long-lived, auto-reconnect) ───────────────────────────

/**
 * Subscribe to the agent status SSE stream.
 * Reconnects automatically with exponential back-off on disconnect.
 * Pass the AbortSignal from a parent AbortController to stop cleanly.
 *
 * Protocol: GET /api/v1/agents/stream → text/event-stream
 */
export function subscribeToAgentEvents(
  callbacks: SSECallbacks,
  signal: AbortSignal,
): void {
  let delayMs = INITIAL_DELAY_MS;

  const connect = async (): Promise<void> => {
    if (signal.aborted) return;

    const token = getToken();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
      "Cache-Control": "no-cache",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/agents/stream`, {
        headers,
        signal,
      });

      if (!response.ok || !response.body) {
        throw new Error(`HTTP ${response.status}`);
      }

      // Successful connection — reset backoff
      delayMs = INITIAL_DELAY_MS;

      await consumeStream(response, callbacks, signal);
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      callbacks.onError?.(error as Error);
    }

    if (!signal.aborted) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, delayMs);
        signal.addEventListener(
          "abort",
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });
      delayMs = Math.min(delayMs * BACKOFF_FACTOR, MAX_DELAY_MS);
      connect();
    }
  };

  connect();
}

// ── Generic GET SSE Stream (reconnecting) ────────────────────────────────────

/**
 * Subscribe to any GET-based SSE endpoint with automatic reconnection.
 * Returns a StreamController for manual cancellation.
 */
export function connectSSE(
  path: string,
  callbacks: SSECallbacks,
  maxAttempts = 5,
): StreamController {
  const outer = new AbortController();
  const { signal } = outer;
  let attempt = 0;
  let delayMs = INITIAL_DELAY_MS;

  const connect = async (): Promise<void> => {
    if (signal.aborted) return;

    const token = getToken();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
      "Cache-Control": "no-cache",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}${path}`, {
        headers,
        signal,
      });

      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      attempt = 0;
      delayMs = INITIAL_DELAY_MS;

      await consumeStream(response, callbacks, signal);
    } catch (error) {
      if ((error as Error).name === "AbortError") return;

      callbacks.onDisconnect?.();

      if (attempt >= maxAttempts) {
        callbacks.onError?.(
          new Error(`SSE: max reconnect attempts (${maxAttempts}) exceeded`),
        );
        return;
      }
    }

    if (!signal.aborted) {
      attempt++;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, delayMs);
        signal.addEventListener(
          "abort",
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });
      delayMs = Math.min(delayMs * BACKOFF_FACTOR, MAX_DELAY_MS);
      connect();
    }
  };

  connect();

  return { abort: () => outer.abort() };
}
