---
globs: ["**/*"]
description: "How to approach performance optimization. EDIT THIS FILE to add your insights."
---

# Performance Optimization Behavior Guide

**HUMAN EDIT SECTION** - Add your performance insights below the line.

## Default Performance Protocol

### Golden Rule
**Measure before optimizing. Never guess.**

### 1. Profile First
- Identify actual bottleneck
- Don't optimize based on assumptions
- Use appropriate profiling tools

### 2. Set Target
- Define specific metric (latency, throughput, memory)
- Set measurable goal
- Know when to stop

### 3. Optimize
- Fix the bottleneck
- One change at a time
- Measure after each change

### 4. Verify
- Confirm improvement
- Check for regressions
- Load test if applicable

## Profiling Tools

### Go
```bash
# CPU profile
go test -cpuprofile=cpu.prof -bench=.
go tool pprof cpu.prof

# Memory profile
go test -memprofile=mem.prof -bench=.

# Trace
go test -trace=trace.out -bench=.
go tool trace trace.out
```

### Node.js
```bash
# Built-in profiler
node --prof app.js
node --prof-process isolate-*.log

# Clinic.js
npx clinic doctor -- node app.js
```

### Frontend
```javascript
// Performance API
performance.mark('start');
// ... code ...
performance.mark('end');
performance.measure('operation', 'start', 'end');
```

## Common Optimizations

### Database
- Add indexes for frequent queries
- Avoid N+1 queries
- Use connection pooling
- Cache frequently accessed data

### API
- Pagination for list endpoints
- Response compression
- Caching headers
- Async where possible

### Frontend
- Lazy loading
- Code splitting
- Image optimization
- Virtualization for lists

---

## YOUR INSIGHTS (Edit Below)

<!--
Add your own performance insights here. Examples:

### Our Performance Targets
- API p99 latency: <200ms
- Page load: <2s
- Database queries: <50ms

### Known Bottlenecks
- User search is slow - needs Elasticsearch
- Dashboard loads all data - needs pagination

### Our Profiling Setup
- Use Datadog APM for production profiling
- Grafana dashboards at: [link]
- Load testing with k6

### Caching Strategy
- Redis for session data (TTL: 24h)
- CDN for static assets
- Browser cache for API responses (5min)
-->

### Our Performance Targets
<!-- Add your targets -->

### Known Bottlenecks
<!-- Add known issues -->

### Our Profiling Setup
<!-- Add profiling tools/dashboards -->

### Caching Strategy
<!-- Add caching approach -->

### Load Testing
<!-- How we load test -->
