// src/lib/services/sse.ts

import type { SSEEvent } from "$lib/types/chat";

export interface SSECallbacks {
  onEvent: (event: SSEEvent) => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onError: (err: Error) => void;
}

export interface SSEConnection {
  close: () => void;
}

const INITIAL_DELAY_MS = 1_000;
const MAX_DELAY_MS = 30_000;
const BACKOFF_FACTOR = 2;

export function connectSSE(
  url: string,
  callbacks: SSECallbacks,
  maxAttempts: number = 5,
): SSEConnection {
  let es: EventSource | null = null;
  let attempt = 0;
  let delay = INITIAL_DELAY_MS;
  let closed = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  function connect() {
    if (closed) return;

    es = new EventSource(url);

    es.addEventListener("open", () => {
      attempt = 0;
      delay = INITIAL_DELAY_MS;
      callbacks.onConnect();
    });

    // The Elixir backend sends all payloads as generic `message` events
    // with JSON-encoded data on each line.
    es.addEventListener("message", (ev: MessageEvent<string>) => {
      try {
        const parsed: SSEEvent = JSON.parse(ev.data);
        callbacks.onEvent(parsed);
      } catch {
        callbacks.onError(new Error(`Unparseable SSE data: ${ev.data}`));
      }
    });

    es.addEventListener("error", () => {
      es?.close();
      es = null;
      callbacks.onDisconnect();

      if (closed) return;
      if (attempt >= maxAttempts) {
        callbacks.onError(
          new Error(`SSE: max reconnect attempts (${maxAttempts}) exceeded`),
        );
        return;
      }

      attempt++;
      reconnectTimer = setTimeout(() => {
        delay = Math.min(delay * BACKOFF_FACTOR, MAX_DELAY_MS);
        connect();
      }, delay);
    });
  }

  connect();

  return {
    close() {
      closed = true;
      if (reconnectTimer !== null) clearTimeout(reconnectTimer);
      es?.close();
      es = null;
    },
  };
}
