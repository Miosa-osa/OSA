# Example: Real-Time Chat — Reliability + Scale Sprint

> Fictional real-time chat application. Elixir + Phoenix + LiveView + PostgreSQL + Redis.

Demonstrates:
- **Execution traces through concurrent systems** — tracing message ordering through PubSub broadcast timing
- **Chain execution on OTP processes** — GenServer memory leak traced from handle_info to unbounded state growth
- **Execution pace** — DATA works slow/careful on ordering guarantees, INFRA works fast on Redis config
- **Merge validation risk** — DATA's ordering fix and INFRA's Redis PubSub must merge cleanly
- **QA load testing** — 10K concurrent connections as acceptance criteria, not just unit tests
- **Cross-stack tracing** — Chain 2 goes from JS client (socket.reconnect) through Elixir (Phoenix.Socket) to OTP (Presence GenServer)
