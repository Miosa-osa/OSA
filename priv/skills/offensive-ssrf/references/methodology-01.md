## Full Methodology

# Server-Side Request Forgery (SSRF)

## Shortcut

- Spot the features prone to SSRF and take notes for future reference.
- Set up a callback listener to detect blind SSRF by using an online service, Netcat, or Burp's Collaborator feature.
- Provide the potentially vulnerable endpoints with common internal addresses or the address of your callback listener.
- Check if the server responds with information that confirms the SSRF. Or, in the case of a blind SSRF, check your server logs for requests from the target server.
- In the case of a blind SSRF, check if the server behavior differs when you request different hosts or ports.
- If SSRF protection is implemented, try to bypass it by using the strategies discussed in this chapter.
- Pick a tactic to escalate the SSRF.

```mermaid
flowchart LR
    A[Identify SSRF Vectors] --> B[Setup Callback Listener]
    B --> C[Test Internal Addresses]
    C --> D{Response Contains\nInternal Data?}
    D -->|Yes| E[Basic SSRF Confirmed]
    D -->|No| F[Check Callback\nListener Logs]
    F --> G{Callbacks\nReceived?}
    G -->|Yes| H[Blind SSRF Confirmed]
    G -->|No| I[Try Bypass Techniques]
    I --> J[Retest with Bypasses]
    E --> K[Escalate SSRF]
    H --> K
    J --> D
```

## Mechanisms

Server-Side Request Forgery (SSRF) is a vulnerability that allows attackers to induce a server-side application to make requests to an unintended location. In a successful SSRF attack, the attacker can force the server to connect to:

- Internal services within the organization's infrastructure
- External systems on the internet
- Services on the same server (localhost)
- Cloud service provider metadata endpoints

```mermaid
graph TD
    A[Attacker] -->|Sends crafted request| B[Vulnerable Web App]
    B -->|Makes request to| C[Unintended Target]
    C -->|Responds with data| B
    B -->|Includes response data| A

    subgraph "Possible Targets"
        C
        D[Internal Network Services]
        E[Cloud Metadata Service]
        F[External Web Services]
        G[Local Services on Same Server]
    end

    C --- D
    C --- E
    C --- F
    C --- G
```

Types of SSRF include:

- **Basic SSRF**: Direct requests to internal/external resources
- **Blind SSRF**: No response returned, but requests still occur
- **Semi-blind SSRF**: Limited information returned in responses
- **Time-based SSRF**: Detection through response timing differences
- **Out-of-band SSRF**: Secondary channel used for data exfiltration

## Hunt

### Identifying SSRF Vectors

- **URL Input Fields**:
  - Website preview generators
  - Document/image imports from URLs
  - API integrations with external services
  - Webhook configurations
  - Export to PDF/screenshot functionality

- **Proxy Functionality**:
  - Web proxies
  - Content fetchers
  - API gateways
  - Translation services

- **File Processing**:
  - Media conversion tools
  - Document processors
  - XML/JSON processors with external entity support

- **Integration Points**:
  - Third-party service connections
  - Cloud storage integrations
  - Monitoring systems
  - Webhook endpoints

```mermaid
mindmap
  root((SSRF Vectors))
    URL Input Fields
      Website Previews
      URL Imports
      API Integrations
      Webhooks
      PDF/Screenshot Export
    Proxy Functionality
      Web Proxies
      Content Fetchers
      API Gateways
      Translation Services
    File Processing
      Media Converters
      Document Processors
      XML/JSON Processors
    Integration Points
      Third-party Services
      Cloud Storage
      Monitoring Systems
      Webhook Endpoints
```

### Test Methodology

1. **Identify Parameters**: Find URL or hostname parameters
2. **Setup Listener**: Configure a system to detect callbacks
   - Public server with unique URL
   - Burp Collaborator
   - Tools like Interactsh or canarytokens.org
3. **Test Internal Access**: Try accessing internal resources
   ```
   http://localhost:port
   http://127.0.0.1:port
   http://0.0.0.0:port
   http://internal-service.local
   http://169.254.169.254/ (cloud metadata)
   ```
4. **Observe Responses**: Check for:
   - Response time differences
   - Error messages
   - Content leakage
   - Callbacks to your server

```mermaid
sequenceDiagram
    participant Attacker
    participant WebApp as Vulnerable Web App
    participant Internal as Internal Services
    participant CallbackServer as Attacker's Callback Server

    Note over Attacker,CallbackServer: Phase 1: Basic SSRF Testing

    Attacker->>WebApp: Request with Internal URL<br>(http://localhost:8080)
    WebApp->>Internal: Makes request to internal service
    Internal->>WebApp: Response from internal service
    WebApp->>Attacker: Leaked internal response

    Note over Attacker,CallbackServer: Phase 2: Blind SSRF Testing

    Attacker->>WebApp: Request with Callback URL<br>(http://attacker-server.com/unique-id)
    WebApp->>CallbackServer: Makes request to callback server
    CallbackServer->>Attacker: Log notification of request

    Note over Attacker,CallbackServer: Phase 3: Bypass Testing

    Attacker->>WebApp: Request with Obfuscated URL<br>(http://127.0.0.1.attacker.com)
    WebApp->>CallbackServer: Makes request due to parser confusion
    CallbackServer->>Attacker: Log notification of successful bypass
```

### Bypass Techniques Hunting

- Look for partial validation or URL parsing issues
- Test scheme changes (http→https, http→file)
- Try different IP formats (decimal, octal, hex)
- Use URL shorteners if allowed
- Check DNS rebinding possibilities

## Bypass Techniques

### Allowlist Bypasses

- **Open Redirects**: Using allowed domains with redirect parameters
  ```
  https://allowed-domain.com/redirect?url=http://internal-server
  ```
- **DNS Spoofing**: Register expired domains from allowlist
- **Subdomain Takeover**: Control subdomains of allowed domains
- **Path Traversal**: `https://allowed-domain.com@evil.com`

### Denylist Bypasses

- **Alternate IP Representations**:
  ```
  http://127.0.0.1/
  http://127.1/
  http://0177.0.0.1/
  http://0x7f.0.0.1/
  http://2130706433/ (decimal representation)
  ```
- **IPv6 Variations**:
  ```
  http://[::1]/
  http://[::127.0.0.1]/
  http://[0:0:0:0:0:ffff:127.0.0.1]/
  ```
- **Domain Resolutions**:
  ```
  http://localhost.evil.com/ (when attacker controls evil.com DNS)
  http://spoofed-domain/ (with modified /etc/hosts)
  ```
- **URL Encoding Tricks**:
  ```
  http://127.0.0.1/ → http://127%2e0%2e0%2e1/
  http://localhost/ → http://%6c%6f%63%61%6c%68%6f%73%74/
  ```
- **Non-Standard Ports**: Accessing standard services on non-standard ports
- **Case Manipulation**: `http://LoCaLhOsT/`
- **URL Schema Confusion**: `http:////localhost/`

```mermaid
flowchart TD
    A[SSRF Protection Bypass] --> B[Allowlist Bypass]
    A --> C[Denylist Bypass]

    B --> B1[Open Redirects]
    B --> B2[DNS Spoofing]
    B --> B3[Subdomain Takeover]
    B --> B4[Path Traversal]

    C --> C1[IP Representation Tricks]
    C1 --> C1a[Decimal: 2130706433]
    C1 --> C1b[Octal: 0177.0.0.1]
    C1 --> C1c[Hex: 0x7f.0.0.1]
    C1 --> C1d[Shortened: 127.1]

    C --> C2[IPv6 Variations]
    C2 --> C2a["[::1]"]
    C2 --> C2b["[::127.0.0.1]"]

    C --> C3[Domain Tricks]
    C3 --> C3a[localhost.evil.com]
    C3 --> C3b[spoofed-domain]

    C --> C4[Encoding Tricks]
    C4 --> C4a[URL Encoding]
    C4 --> C4b[Double Encoding]

    C --> C5[Schema Confusion]
    C5 --> C5a["http:////localhost"]

    style A fill:#f96,stroke:#333,stroke-width:2px,color:#333
    style B fill:#aae,stroke:#333,color:#333
    style C fill:#aae,stroke:#333,color:#333
```

### Uncommon Techniques

- **DNS Rebinding**: Change DNS resolution mid-connection
- **Temporal Intents**: Reliance on stale DNS resolution
- **Double URL Encoding**: Encode already encoded values
- **Unicode Normalization**: Using similar-looking characters
- **Protocol Downgrading**: Switching from https to http

### Additional Cloud Endpoints

- **Alibaba Cloud**: `http://100.100.100.200/latest/meta-data/`
- **Packet Cloud**: `https://metadata.packet.net/userdata`
- **ECS Task**: `http://169.254.170.2/v2/credentials/`
- **OpenStack**: `http://169.254.169.254/openstack/latest/meta_data.json`

### Other Bypass Methods

- **Weak Parser Exploits**:
  ```
  http://127.1.1.1:80\@127.2.2.2:80/
  http://127.1.1.1:80\@@127.2.2.2:80/
  http://127.1.1.1:80:\@@127.2.2.2:80/
  ```
- **Filter Bypass**:
  ```
  0://evil.com:80;http://google.com:80/
  ```
- **Enclosed Alphanumerics**: Using special Unicode characters that look like regular characters
  ```
  http://ⓔⓧⓐⓜⓟⓛⓔ.ⓒⓞⓜ
  ```
- Host header abuse (`Host:` or `X-Forwarded-Host:`) against permissive back-end proxies
- Unicode homoglyph hostnames (e.g., ⅰⅱⅲ.local) to dodge simple regex checks
- DNS-over-HTTPS lookups (`https://dns.google/resolve?name=…`) to leak internal hostnames

