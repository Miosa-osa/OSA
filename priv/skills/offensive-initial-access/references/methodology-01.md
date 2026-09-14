## Full Methodology

# Modern Initial Access

## Introduction

### Typical Initial Access Vectors

- Email with malware attached/linked
  - Most attacks using attached malware won't work
  - Out of the box protection may not cover `PDF, ISO, IMG, HTML, SVG, PPTM, PPSM, ACCDE`
  - Most URL-based attacks do work
  - domain's reputation, age, category should be sound
  - domain should use https
  - limit number of GET elements and their names
  - use HTML Smuggling to evade
  - get your domain warmed up (send some legitimate emails first with no attachment and links)
  - Advanced attacks may involve delivering backdoored trusted applications (e.g., older Electron apps with V8 exploits) via phishing to bypass application control like WDAC.
- Spear-phishing/ phishing / stealing valid credentials
  - Check your mail with [Phishious](https://github.com/CanIPhish/Phishious) before sending it to your victim
  - use [decode-spam-headers](https://github.com/mgeeky/decode-spam-headers) to analyze returned SMTP headers
  - Be aware that default Microsoft Office settings now block macros in files downloaded from the internet (marked with `MOTW`). Success often requires significant social engineering to convince users to bypass these protections or using alternative delivery methods (e.g., containers that don't propagate `MOTW`, signed add-ins).
  - images and link increase spam score, be wary of it
  - don't use `no-reply` like usernames
  - send through `GoPhis -> AWS SOCAT :587 -> smtp.gmail.com -> @target.com`
  - link to websites on trusted domains, like cloud-facing resources
  - make sure your webserver blocks automated bots
- Deep‑fake voice or video social‑engineering calls (help‑desk or executive impersonation) to obtain password resets or approve MFA prompts. Generative‑AI tools make cloning voices trivial.
- Business Email Compromise (BEC) / OAuth consent phishing that targets finance or vendor‑portal users, yielding cloud‑token access even where MFA is enabled.
- Malicious OneNote `.one` attachments and OneDrive "Add to Shortcut" abuse: embedded HTA/JS payloads bypass Office macro blocking and spread via cloud sync.
- Excel blocks untrusted Internet-origin XLL add-ins by default (M365, 2023+). Smuggled XLLs inside containers may still be blocked once MOTW propagates.
- Malicious browser extensions (Chrome, Edge, Firefox) delivered through fake Web Store listings; hijack session cookies or inject scripts into authenticated SaaS sessions.
- attackers register malicious cloud apps and trick users into granting scopes, giving token-based access that bypasses MFA
- Reusing stolen credentials against external single factor VPN, gateways, etc
- Password Spraying against Office365, custom login pages, VPN gateways
- Exposed RDP with weak credentials and lacking controls
- Unpatched known vulnerable perimeter device, application bugs, default credentials, etc
- Rarely HID-emulating USB sticks
- WiFi Evil Twin -> Route WPA2 Enterprise -> NetNTLMv2 hash cracking -> authenticated network access -> Responder
- Plugging into on-premises LAN -> Responder/mitm6/Ldaprelayx
- SEO poisoning / paid‑search malvertising (e.g., fake PuTTY & WinSCP ads, dominant loader delivery 2024–25) and "quishing" PDFs whose QR codes redirect victims to mobile OAuth login pages
- Consent‑/token‑phishing and Adversary‑in‑the‑Middle (AiTM) proxy kits that steal OAuth session cookies or proxy MFA (e.g., EvilProxy, Tycoon, Dadsec). These vectors bypass MFA by tricking users into granting access to rogue Azure AD / Google Workspace apps.
- Supply‑chain compromise of developer ecosystems:
  - malicious NPM / PyPI typosquat packages
  - poisoned GitHub Actions or CI/CD secrets exfiltration
  - container‑registry deception (imageless Docker Hub repos or `curl | bash` installers).
  - First contact often occurs on developer workstations.
- Mass‑exploited perimeter and edge‑device zero‑days (e.g., Ivanti Connect Secure (such as CVE-2023-46805, CVE-2024-21887), MOVEit Transfer (such as CVE-2023-34362), Citrix Bleed) enabling unauthenticated remote code execution **before** credentials come into play. Maintain a live "current CVEs exploited‑in‑the‑wild" table and apply virtual patching/WAF rules where upgrades lag.
- Cloud & Kubernetes misconfigurations:
  - exposed S3 buckets allowing upload‑then‑execute objects
  - SSRF into EC2 IMDSv1 or GCP metadata to steal instance credentials
  - open Kubernetes API/Argo CD dashboards, and leaked Azure SAS tokens that grant cross‑tenant data extraction.
  - OIDC Workload Identity Federation exposed: stolen GKE/EKS service‑account tokens grant cross‑cluster privilege escalation.
  - AWS STS credentials embedded in shareable URLs (`GetFederationToken`, presigned S3, etc.) leak temporary keys to attackers.
- Mobile initial‑access vectors:
  - smishing or WhatsApp/Telegram lures
  - QR‑code invoice/resumé phishing that lands on mobile browsers
  - rogue Mobile Device Management (MDM) enrolment profiles granting full device admin.
  - Passkey/WebAuthn phishing pages that spoof the biometric prompt to hijack FIDO sessions.
  - Sideload invitations via fake Apple TestFlight or Test Fairy links deliver malicious iOS/Android apps outside official store review.
- Collaboration‑app abuse:
  - malicious Microsoft Teams/Slack/Discord apps with overbroad OAuth scopes
  - slash‑command token vacuum
  - SharePoint Framework (SPFx) app sideloading
  - Discord/Telegram CDN links hosting first‑stage binaries.
- If WinRM over HTTPS (WinRMS, port 5986) is enabled (it's not by default) and its Channel Binding setting remains at the default "Relaxed", it becomes vulnerable to NTLM relay attacks. Relayed credentials (e.g., from coerced HTTP/SMB/LDAP) can grant RCE. Ironically, enabling WinRMS to "harden" a system by disabling HTTP WinRM (port 5985, which _is_ relay-resistant due to internal encryption) can introduce this vulnerability. Key technical details:
  - Standard WinRM (port 5985) uses HTTP with SPNEGO; channel binding is enabled by default, so NTLM relay fails unless the attacker controls TLS.
  - WinRMS (port 5986) runs over HTTPS; if `CbtHardeningLevel` is not set to **Strict**, credentials can still be relayed despite TLS.
  - Channel Binding (CBT) can be set to None (disabled), Relaxed (optional), or Strict (required)
  - Mitigation: `winrm set winrm/config/service/auth '@{CbtHardeningLevel="Strict"}'`
  - Prefer Kerberos or certificate-based auth for WinRM; monitor and reduce NTLM usage.
- Exploiting misconfigured Power Platform services (e.g., Power Apps with overly permissive shared connections or abusing Power Query for native SQL execution against on-prem data gateways).

### Command & Control

- Use a two-stage [Mythic C2](https://github.com/its-a-feature/Mythic) as our command and control
- Stage one should be lean and hard to detect, it would be used for situational awareness
  - [Merlin](https://github.com/MythicAgents/merlin) for Linux (no upstream commits since 2023, still functional)
  - [Poseidon](https://github.com/MythicAgents/poseidon) + [Apfell](https://github.com/MythicAgents/apfell) for macOS
  - [Apollo](https://github.com/MythicAgents/Apollo) in shellcode form for Windows
    - to get rid of apollo console
    - open it via `detect-it-easy`, select `pe` and uncheck `readonly`
    - then select `WINDOWS_GUI` in `Subsystem` inside `IMAGE_OPTIONAL_HEADER`
    - also notice apollo is a 32-bit executable
  - also checkout [Nimplant](https://github.com/MythicAgents/Nimplant) or [others](https://mythicmeta.github.io/overview/)
  - [Nighthawk](https://nighthawkc2.io/evanesco/)
- Stage two should be in-memory, inline-execute and feature reach
  - Nighthawk, Cobalt Strike, etc

### Exec/DLL to SHELLCODE

For detailed information on converting executables and DLLs to shellcode, including:

- Embedding shellcode into loaders
- Backdooring legitimate PE executables
- Tools like Donut, sRDI, Pe2shc and Amber
- Open-source shellcode loaders like ScareCrow and NimPackt-v1

See the [Shellcode documentation](/exploit/shellcode.md).

### EDR Evasion Techniques

For detailed information on EDR evasion techniques, including:

- Malware Virtualization
- API Unhooking
- Early Cascade Injection
- Killing Bit techniques
- Call Stack Obfuscation
- Sleep Obfuscation

See the [EDR Evasion documentation](/exploit/edr.md)

### Modern CyberDefense Stack

- Secure Email Gateway / Email Security
  - FireEye MX
  - Cisco Email Security
  - TrendMicro for Email
  - MS Defender for Office365
- Secure Web Gateway
  - Symantec BlueCoat
  - PaloAlto Proxy
  - Zscaler
  - FireEye NX
- Secure DNS
  - Cisco Umbrella
  - DNSFilter
  - Akamai Enterprise Threat Protector
- AntiVirus
  - McAfee
  - ESET
  - Symantec
  - BitDefender
  - Kaspersky
- EDR
  - CrowdStrike Falcon
  - MS Defender for Endpoint
  - SentinelOne
  - VMware Carbon Black

### Defensive quick‑wins

- Email/web controls
  - Enable Microsoft Defender for Office 365 Safe Links and Safe Attach (or vendor equivalent).
  - Block direct download of executable formats; detonate unknowns in sandbox.
- Office hardening
  - Keep "Block macros from the Internet (MOTW)" enforced; prefer trusted locations.
  - Block XLL add‑ins, unsigned COM add‑ins, and legacy Excel 4.0 macros
  - ASR rules: Block Office child processes; Block Win32 API calls from Office; Block executable content from email and webmail; Block credential stealing from LSASS.
- Browser/extension control
  - Enforce extension allowlists (Chrome/Edge/Firefox policy); disable developer mode on managed devices.
- Identity & auth
  - Enforce MFA; restrict OAuth app consent (publisher verification + admin consent workflows); tenant restrictions.
  - Prefer phishing‑resistant MFA (FIDO2/CTAP); block legacy/basic auth; monitor device‑code flow abuse.
- Endpoint policies
  - WDAC/Smart App Control or application allow‑listing for untrusted installers (MSI/MSIX/ClickOnce).
  - Monitor and restrict PowerShell Constrained Language Mode exceptions; log script block.
  - For WinRM: prefer Kerberos/certificate auth; set WinRMS channel binding to Strict: `winrm set winrm/config/service/auth '@{CbtHardeningLevel="Strict"}'`.

## Security Controls Evasion

### Perimeter Defense Evasion

#### Secure Web Gateway

- sensitive on
  - Domain characteristics
  - URL-fetched contents (HTML, body, javascript)
  - MIME types (where file type is allowed or not)
- can be evaded via
  - high reputation servers (cloud instances)
  - HTML smuggling

#### Secure DNS

- sensitive on
  - Domain categorisation, maturity, `whois` examination
  - Presence on real-time blocking lists, threat intelligence feeds, virustotal-alike databases
  - SSL/TLS certificate contents
- can be evaded via
  - high reputation domains (Domain fronting CDN like azure edge CDN, Cloud-based resources like AWS lambda or azure blob storage, personal cloud drives)
  - use [Talos Intelligence](https://talosintelligence.com/reputation_center/) to check reputation
  - AWS is dumber than Azure, use it

### Endpoint Defense Evasion

#### Antivirus

- sensitive on
  - static signatures
  - heuristic signatures
  - behavioural signatures
  - trigger events `on-demand -> on-write -> on-access -> on-execute -> real-time`
  - proactive protection of them is weaker due to low false-positive, low impact and high stability requirements
    - before-exec: mainly cloud-reputation based examination
    - before-exec: machine learning evaluation focusing on hand-picked characteristics
    - on-exec: simulating entry point and first N instructions
    - on-exec: memory scanner sweeping process virtual memory allocations for presence of signatured threats
  - steps
    - static analysis
    - heuristic analysis
    - cloud reputation analysis + automated sandboxing / detonation
    - ML analysis
    - emulation
    - behavioural analysis
- can be evaded via
  - static analysis by writing custom malware
  - heuristic analysis by smartly blending-in with our payload
  - cloud reputation by backdooring legitimate binaries, devising malware in containers (PDF, Office docs), sticking to DLLs
  - automated sandboxing by environmental keying (only execute if something)
  - ML analysis by trial and error, hard to combat
  - emulation by time-delaying, environmental keying
  - behavioural analysis by
    - avoiding suspicious WinAPI calls
    - acting low-and-slow instead of all-at-once
    - unhooking/direct syscalls may work

#### EDR Evasion Techniques

For detailed information on EDR evasion techniques, including:

- Malware Virtualization
- API Unhooking
- Early Cascade Injection
- Killing Bit techniques
- Call Stack Obfuscation
- Sleep Obfuscation
- Telemetry obfuscation
- Persistence strategies
- Event correlation evasion

See the [EDR Evasion documentation](exploit/edr.md).

### Windows Defender Bypass Techniques

For detailed information on Windows Defender bypass techniques, including ASR bypasses and custom detection rules evasion, see the [EDR Evasion documentation](exploit/edr.md).

## Hosting Payloads

- Server Hosting our Payload must
  - Look benign, best if commonly used for file hosting
  - Have SSL/TLS certificate signed by trusted authority
  - Hard to be blocked by target (cloud based)
- Example
  - Cloud-based file storage: Office365 OneDrive, SharePoint, AWS S3, MS Azure Storage, Google Drive, FireBase Storage
  - CDN: Azure Edge CDN, StackPath, Fastly, Akamai, Google Cloud AppSpot, HerokuApp
  - Serverless Endpoints: AWS Lambda, CloudFlare Workers, DigitalOcean Apps
- use [LOTS Project](https://lots-project.com/) for help
- use [LOLBINS](https://lolbas-project.github.io/)
  - prefer DLL over EXE
  - indirect execution to circumvent EDR/AV
  - DLL Side-Loading / DLL Hijacking / COM Hijacking / XLL
- check [Microsoft Block Rules](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/design/applications-that-can-bypass-wdac) to better circumvent defender

## Infection Vectors and Chains

### Classic File Infection Vectors

#### MAC

- initial access is getting harder, for example for MAC you can still bypass
  - Unsigned apps (gets through with few clicks)
  - Office Macros + `.SLK` Excel4 macros (constrained by gatekeeper)
  - you can use [Mystikal](https://github.com/D00MFist/Mystikal)
- Use `LNK, CHM, CPL, DLL, MSI, HTML, SVG`; hold `Office w/macros, ISO, VHD, XSL`.

