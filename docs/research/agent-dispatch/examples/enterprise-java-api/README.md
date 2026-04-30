# Example: Enterprise Java API — Performance + Event Reliability Sprint

> Fictional enterprise inventory management system. Java 17 + Spring Boot 3 + Hibernate/JPA + PostgreSQL + Kafka + React.

Demonstrates:
- **Execution traces through enterprise layered architecture** — tracing performance bugs from HTTP controller down through service → repository → JPA entity, following Spring's layered separation strictly (each layer owns its boundary)
- **N+1 query hunting with Hibernate** — classic enterprise performance problem where lazy-loaded associations explode a single list request into tens of thousands of SQL round-trips; DATA traces the exact fetch strategy before touching anything
- **Cross-service tracing through Kafka events** — Chain 2 follows a `StockUpdateEvent` from producer through broker partition assignment to consumer group rebalance, requiring SERVICES to reason about offset commit semantics and partition reassignment windows
- **Execution pace: DATA slow/careful on JPA entity relationships** — changing fetch strategy on a `@ManyToOne` cascade has hidden blast radius (affects every query that touches the entity); DATA audits all `@EntityGraph` usages and existing JPQL before proposing a fix
- **Execution pace: SERVICES moderate on Kafka consumer group rebalancing** — consumer group state is distributed and time-sensitive; SERVICES must understand the current `max.poll.interval.ms` and `session.timeout.ms` configuration before adjusting, then verify partition reassignment completes cleanly after deployment
