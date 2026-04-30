# Sprint 03 Dispatch — Reliability + Scale

> Fix message ordering, connection drops, memory leaks. Prepare for 10K concurrent users.
> Stack: Elixir + Phoenix + LiveView + PostgreSQL + Redis PubSub

## Sprint Goals

1. Fix message ordering bug (messages arrive out of order under load)
2. Fix WebSocket reconnection (clients stuck in disconnected state)
3. Fix memory leak in presence tracking (GenServer state grows unbounded)
4. Add horizontal scaling support (multiple nodes via Redis PubSub)
5. Load test: 10K concurrent connections, <100ms message delivery

## Execution Traces

### Chain 1: Message Ordering (P1)
```
User sends message → LiveView handle_event("send_message")
→ Chat.create_message() → Repo.insert() → PubSub.broadcast()
→ Other clients receive via handle_info({:new_message, msg})
Signal: Under load, broadcast arrives before Repo.insert() commits.
Receiving client queries DB, message not found yet. Retry displays out of order.
```

### Chain 2: WebSocket Reconnection (P1)
```
Client disconnects (network blip) → Phoenix.Socket.disconnect()
→ Client JS: socket.reconnect() → mount() called again
→ Presence.track() → DUPLICATE presence entry (old + new)
Signal: Old presence never cleaned up. User appears "online" twice.
After 3 reconnects, presence list is polluted.
```

### Chain 3: Presence Memory Leak (P1)
```
PresenceServer GenServer state grows with every join/leave event.
→ handle_info({:presence_diff, diff}) appends to state.history
→ state.history never trimmed → OOM after 48 hours
Signal: Observer shows PresenceServer process at 2GB after 2 days.
```

### Chain 4: Multi-Node PubSub (P2)
```
Node A broadcasts message → only Node A subscribers receive it
→ Node B users never get the message
Signal: Phoenix.PubSub uses local PG (process groups). No cross-node routing.
Need Redis adapter for PubSub.
```

## Wave Assignments

### Wave 1 — Foundation

| Agent | Focus | Chains |
|-------|-------|--------|
| DATA | Fix message insert → broadcast ordering (use Repo.transaction + broadcast after commit) | Chain 1 |
| QA | Write concurrent message ordering test, presence leak test | Chain 1, 2, 3 |
| INFRA | Add Redis to docker-compose, configure PubSub adapter | Chain 4 |

### Wave 2 — Backend

| Agent | Focus | Chains |
|-------|-------|--------|
| BACKEND | Fix presence cleanup on reconnect, add heartbeat timeout | Chain 2 |
| SERVICES | Fix PresenceServer memory leak (bounded history, periodic trim) | Chain 3 |

### Wave 3 — Frontend

| Agent | Focus | Chains |
|-------|-------|--------|
| FRONTEND | Add reconnection indicator UI, optimistic message rendering, offline queue | Chain 1, 2 |

## Merge Order

```
1. DATA → main  (message ordering — foundational)
2. BACKEND   → main  (presence cleanup)
3. SERVICES   → main  (memory leak fix)
4. INFRA → main  (Redis PubSub — multi-node)
5. FRONTEND   → main  (frontend reconnection UX)
6. QA    → main  (tests validate under load)
```

## Success Criteria

- [ ] Messages arrive in order under 1K concurrent senders
- [ ] WebSocket reconnection works cleanly (no duplicate presence)
- [ ] PresenceServer memory stable over 72 hours (<100MB)
- [ ] Messages delivered across 2+ nodes via Redis PubSub
- [ ] 10K concurrent connections sustained with <100ms p95 delivery
- [ ] Load test results documented
