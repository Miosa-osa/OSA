# Sprint 06 Dispatch — Performance + Event Reliability

> Fix inventory list N+1 queries, Kafka consumer lag, optimistic locking failures, connection pool exhaustion, and unbounded pagination
> Stack: Java 17 + Spring Boot 3.2 + Hibernate 6 + PostgreSQL 16 + Apache Kafka + React 18 + TypeScript

## Sprint Goals

1. Fix N+1 query on inventory list (`GET /api/inventory`: 2000ms → <200ms)
2. Fix Kafka consumer lag causing stale inventory counts (consumer group rebalance drops uncommitted offsets)
3. Fix optimistic locking failure on concurrent stock updates (`StaleObjectStateException` under parallel writes)
4. Tune HikariCP connection pool (currently exhausted by batch sync job, starving REST API)
5. Add pagination to inventory list (currently loads all 50K+ items into memory)

## Execution Traces

### Chain 1: Inventory List N+1 Query (P1)
```
GET /api/inventory
→ InventoryController.list()
→ InventoryService.findAll()
→ InventoryRepository.findAll()          // returns List<Inventory> with LAZY associations
→ Hibernate: SELECT * FROM inventory     // 50,000 rows loaded
→ FOR EACH item: SELECT * FROM warehouse WHERE id = ?   // 50,000 queries
→ FOR EACH item: SELECT * FROM supplier  WHERE id = ?   // 50,000 queries
Signal: 100,000+ SQL queries per request. Response time 2000ms+.
Root cause: @ManyToOne(fetch = FetchType.LAZY) on Inventory.warehouse and Inventory.supplier.
No @EntityGraph or JOIN FETCH in repository. Jackson serializer triggers proxy initialization
for every item in the response DTO mapping loop inside InventoryService.toDto().
```

### Chain 2: Kafka Consumer Lag / Stale Inventory Counts (P1)
```
WarehouseService.adjustStock()
→ kafkaTemplate.send("stock-updates", StockUpdateEvent)
→ [Kafka broker: stock-updates topic, 12 partitions]
→ StockEventConsumer.onMessage()         // @KafkaListener, concurrency=3
→ inventoryCountService.applyUpdate()
→ inventoryRepository.save()
Signal: During rolling deployment, consumer group "inventory-consumer-group" triggers
partition rebalance. Default rebalance protocol reassigns all 12 partitions.
Consumer pod going down has not yet committed offsets for 847 in-flight messages.
New pod picks up from last committed offset → 847 events reprocessed → duplicate
inventory decrements → counts drift negative. p99 consumer lag: 45,000 messages.
Root cause: enable.auto.commit=true with auto.commit.interval.ms=5000. Rebalance
fires inside the commit window. No idempotency guard on applyUpdate().
```

### Chain 3: Optimistic Locking Failure — Concurrent Stock Adjust (P2)
```
PUT /api/inventory/:id/adjust
→ InventoryController.adjustStock()
→ InventoryService.adjustStock(id, delta)
→ inventoryRepository.findById(id)       // reads @Version = 7
→ [concurrent: warehouse scanner does same read, version = 7]
→ InventoryService: entity.setQuantity(qty + delta)
→ inventoryRepository.save()             // emits UPDATE ... WHERE version = 7 AND id = ?
→ [warehouse scanner save fires first, version bumped to 8]
→ Web UI save: UPDATE matches 0 rows → Hibernate throws StaleObjectStateException
→ InventoryController has no retry logic → 500 returned to client
Signal: Warehouse scanners and web UI update the same high-velocity SKUs simultaneously.
~200 StaleObjectStateException per hour on top 50 SKUs. No retry, no user feedback.
```

### Chain 4: HikariCP Connection Pool Exhaustion (P2)
```
InventoryBatchSyncJob (Spring @Scheduled, runs every 15 min)
→ inventoryRepository.findAll()          // pulls all 50K rows — same N+1 problem
→ FOR EACH item: externalCatalogClient.fetchDetails()  // blocks on HTTP per item
→ holds DB connection open for entire batch duration (~8 min)
[Concurrent] GET /api/inventory → InventoryService.findAll()
→ DataSourceUtils.getConnection()        // HikariCP maximumPoolSize=10
→ HikariPool: no connections available → wait 30s → HikariTimeoutException
→ REST API returns 500 to all clients during batch window
Signal: HikariCP metrics show pool at 100% utilization for 8-minute windows every 15 min.
maximumPoolSize=10 is Spring Boot default — never tuned for this workload.
Batch job holds connections proportional to item count, not batch chunk size.
```

### Chain 5: Unbounded Pagination — Full Table Scan on List (P2)
```
GET /api/inventory
→ InventoryController.list()
→ InventoryService.findAll()
→ InventoryRepository.findAll()          // Spring Data: no Pageable parameter
→ Hibernate: SELECT * FROM inventory    // 50,000 rows
→ List<Inventory> loaded entirely into heap
→ InventoryService.toDto() maps all 50,000 → List<InventoryDto>
→ Jackson serializes entire list → ~18MB JSON response
Signal: Heap allocation spike of ~600MB per request. GC pressure under concurrent load.
React admin table renders all 50K rows — browser tab freezes for 3–4 seconds.
Root cause: InventoryRepository extends JpaRepository<Inventory, Long> but list
endpoint never passes Pageable. No @PageableDefault. No cursor or keyset pagination.
```

## Wave Assignments

### Wave 1 — Foundation

| Agent | Focus | Chains |
|-------|-------|--------|
| DATA | Audit all `@ManyToOne` fetch strategies on `Inventory`, `Warehouse`, `Supplier` entities. Add `@EntityGraph` with `attributePaths = {"warehouse", "supplier"}` to `InventoryRepository.findAll(Pageable)`. Add `Page<Inventory>` overload. Write Flyway migration to add `idx_inventory_warehouse_id` and `idx_inventory_supplier_id` covering indexes. Fix HikariCP config: `maximumPoolSize=25`, `minimumIdle=5`, `connectionTimeout=3000`. | Chain 1, 4, 5 |
| QA | Write integration tests against embedded H2 + Testcontainers PostgreSQL: verify `findAll` issues exactly 1 SQL query (not N+1), verify `Page<InventoryDto>` response shape, verify `StaleObjectStateException` retry succeeds on second attempt, verify Kafka consumer processes event exactly once under simulated rebalance. | Chain 1, 2, 3 |
| INFRA | Add HikariCP metrics to `application.yml` (`spring.datasource.hikari.register-mbeans=true`). Add Kafka consumer lag alert to `docker-compose.yml` (Prometheus + kafka-lag-exporter). Configure `batch.size` and `spring.kafka.listener.concurrency` in `application.yml`. Verify Testcontainers setup for Kafka in CI pipeline. | Chain 2, 4 |

### Wave 2 — Backend

| Agent | Focus | Chains |
|-------|-------|--------|
| BACKEND | Add `Pageable` parameter to `InventoryController.list()`. Return `Page<InventoryDto>` with `X-Total-Count` header. Add `@ControllerAdvice` handler for `StaleObjectStateException` — retry up to 3 times with exponential backoff using Spring Retry (`@Retryable`). Add `adjustStock` idempotency: accept client-supplied `X-Idempotency-Key` header, store in `idempotency_keys` table (DATA provides migration), return cached response on duplicate. | Chain 3, 5 |
| SERVICES | Switch Kafka consumer from `enable.auto.commit=true` to manual offset commit (`AckMode.MANUAL_IMMEDIATE`). Wrap `StockEventConsumer.onMessage()` with `Acknowledgment.acknowledge()` only after `inventoryRepository.save()` commits. Add idempotency check in `inventoryCountService.applyUpdate()`: deduplicate on `event.eventId` using a `processed_events` table (DATA provides migration). Switch consumer group to cooperative sticky rebalance protocol (`partition.assignment.strategy=CooperativeStickyAssignor`) to eliminate stop-the-world rebalance. Fix `InventoryBatchSyncJob`: use `@Transactional(propagation = REQUIRES_NEW)` per chunk, chunk size 500, release connection between chunks. | Chain 2, 4 |

### Wave 3 — Frontend

| Agent | Focus | Chains |
|-------|-------|--------|
| FRONTEND | Replace flat inventory table with paginated React Query data fetching (`useInfiniteQuery` or cursor-based pagination). Add `page`, `size`, `sort` query params to `GET /api/inventory` calls. Add loading skeleton (no layout shift). Display `X-Total-Count` in table header ("Showing 1–50 of 52,341 items"). Add toast notification for optimistic lock retry ("Item updated — one retry needed") and failure ("Update failed — please refresh"). | Chain 3, 5 |

## Merge Order

```
1. DATA → main  (entity fetch strategy + indexes + HikariCP config + migrations)
2. SERVICES   → main  (Kafka manual commits + cooperative rebalance + batch chunking)
3. BACKEND   → main  (pagination endpoint + StaleObjectStateException retry + idempotency)
4. FRONTEND   → main  (paginated React table + optimistic lock UX)
5. INFRA → main  (metrics + Kafka lag alerting + CI Testcontainers)
6. QA    → main  (integration tests validate all fixes end-to-end)
```

## Success Criteria

- [ ] `GET /api/inventory` issues exactly 1 SQL query (was 100,000+), measured via Hibernate statistics
- [ ] `GET /api/inventory` p99 response time <200ms at 50K rows (was 2000ms+), load tested with k6
- [ ] Kafka consumer lag <1,000 messages during rolling deployment (was 45,000+)
- [ ] Zero duplicate inventory decrements after 1,000 simulated rebalance events
- [ ] `StaleObjectStateException` retried transparently — client receives 200, not 500
- [ ] HikariCP active connections stay below 20 during batch sync window (was 10/10 exhausted)
- [ ] Batch sync job releases connections between chunks — API p99 latency unaffected during batch
- [ ] `GET /api/inventory` returns paginated response (default page size 50), not full 50K rows
- [ ] React admin table renders without freeze on first load
- [ ] All Testcontainers integration tests green in CI

## Worktree Setup

```bash
SPRINT="sprint-06"
PROJECT_DIR="$(pwd)"
PARENT_DIR="$(dirname $PROJECT_DIR)"
PROJECT_NAME="$(basename $PROJECT_DIR)"

for agent in backend frontend infra services qa data lead; do
  git branch $SPRINT/$agent main 2>/dev/null || true
  git worktree add "$PARENT_DIR/${PROJECT_NAME}-${agent}" $SPRINT/$agent
done

# Install Maven dependencies in each worktree
# for agent in backend frontend infra services qa data; do
#   (cd "$PARENT_DIR/${PROJECT_NAME}-${agent}/backend" && ./mvnw dependency:resolve -q)
# done

# Install frontend dependencies
# for agent in backend frontend; do
#   (cd "$PARENT_DIR/${PROJECT_NAME}-${agent}/frontend" && npm install)
# done
```

## Post-Sprint Cleanup

```bash
for agent in backend frontend infra services qa data lead; do
  git worktree remove "$PARENT_DIR/${PROJECT_NAME}-${agent}" 2>/dev/null
  git branch -d $SPRINT/$agent 2>/dev/null
done
```

---

**Sprint Planning Source:** Inventory platform performance audit, Q1 incident retrospective (Kafka lag event 2026-01-14, connection pool exhaustion 2026-01-22)
