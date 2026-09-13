---
name: osint-methodology
description: "Structured OSINT methodology framework: target definition, source selection, collection workflows, data correlation, timeline reconstruction, and reporting. Covers sock-puppet OpSec, cryptocurrency and L2 tracing, image/video geolocation, chronolocation (shadow/astronomical/satellite), threat-actor investigation with attribution discipline, RU/CN-specific pivots, people and social-media investigation, infrastructure OSINT, Telegram/WeChat, case management, and synthetic-media verification. Use to guide systematic OSINT campaigns, teach OSINT methodology, or run the full collection-to-report workflow against any target. Ported from SnailSploit/Claude-Red (Apache-2.0)."
category: security
triggers:
  - "osint methodology"
  - "open source intelligence"
  - "target profiling"
  - "data correlation"
  - "osint workflow"
  - "intelligence collection"
  - "osint campaign"
  - "recon methodology"
  - "geolocation"
  - "chronolocation"
---

# OSINT Methodology

When this skill is active:
1. Apply the methodology below as the operational checklist
2. Follow steps in order unless the operator specifies otherwise
3. For each technique, weigh applicability to the current target/context
4. Track which checklist items are complete
5. Suggest next steps from what each tool returns

CLI tools marked `[LOCAL]` (verified), `[INSTALL]` (one-command install),
`[UPSTREAM-REF]` (reference only — API keys/commercial/interactive).

## OpSec — sock puppets first

- Fake account that cannot be linked to you; build posting history before investigating
- Separate browser profiles/containers per case and persona (Firefox Multi-Account
  Containers); never log into personal accounts from an investigation profile
- Disposable VoIP/SMS numbers (Burner, Silent Link) for platform verification
- Audit every browser extension before install — supply-chain attacks on investigator
  extensions are documented since 2024
- Hardware-backed passkeys for critical accounts; recovery codes offline
- Minimal chain-of-custody: timestamp every action, hash key artifacts, record tool
  versions per case
- References: [Effective Sock Puppets](https://medium.com/@unseeable06/creating-an-effective-sock-puppet-for-your-osint-investigation-95fdbb8b075a),
  [Ultimate Guide to Sockpuppets](https://osintteam.blog/the-ultimate-guide-to-sockpuppets-in-osint-how-to-create-and-utilize-them-effectively-d088c2ed6e36),
  [Fake Name Generator](https://www.fakenamegenerator.com/),
  [This Person Does Not Exist](https://thispersondoesnotexist.com/)

## Cryptocurrency Investigation

### Transaction analysis

- Track flows between wallets; cluster related addresses; watch whale transfers
- Explorers/analytics: Cielo (multi-chain wallet tracking), TRM (relationship graphs),
  Arkham (entity labels + alerts), MetaSleuth (retail visualization), Range/Socketscan/
  Pulsy (bridge explorers), Chainalysis Horizon 2.0 `[UPSTREAM-REF: paid]`,
  Elliptic Lens `[UPSTREAM-REF: paid]`

### Layer 2 / rollup analysis

- zkSync Era / Polygon zkEVM: ZK proofs hide L2 detail; only bridge events visible on
  L1 — use [zkSync Explorer](https://explorer.zksync.io/), [PolygonScan zkEVM](https://zkevm.polygonscan.com/)
- Arbitrum / Optimism: batched calldata; reconstruct from L1 — [Arbiscan](https://arbiscan.io/),
  [Optimistic Etherscan](https://optimistic.etherscan.io/); risk framework at [L2Beat](https://l2beat.com/)
- StarkNet: Cairo VM, different address derivation — [Voyager](https://voyager.online/),
  [StarkScan](https://starkscan.co/)
- Base / Blast / Scroll: OP-Stack/ZK-rollups, same approach
- Privacy protocols: Aztec (noir circuits), Railgun (shielded pools), Privacy Pools
  (association sets) — rely on timing analysis and deposit/withdrawal clustering
- Bridge mixers (Hop, Across, Stargate) break direct tracing via pool swaps; track
  bridge contracts and relayers instead
- Cautions: mint/burn semantics on bridges — never assume 1:1 flows without on-chain
  proof; MEV/aggregator paths create false "direct" trails; vendor labels disagree —
  treat labels as hypotheses; optimistic rollups have 7-day challenge windows

### Wallet / exchange / NFT profiling

- Wallet age, activity patterns, known-entity connections, balance history
- Exchange deposit/withdrawal patterns, linked accounts, compliance posture
- NFT: ownership history, transfers, metadata + hidden content, connected wallets

## Image Analysis

- Contextual reverse search: Google Images/Lens (incognito or sock puppet — Lens
  requires auth for some features), [Yandex Images](https://yandex.com/images/) (strongest
  for faces), [Bing Image Match](https://www.bing.com/images/), [TinEye](https://tineye.com/)
  (first-seen tracking), [Copyseeker](https://copyseeker.com/) (AI), Perplexity Pro
  (contextual AI analysis)
- Extensions: [RevEye](https://chromewebstore.google.com/detail/reveye-reverse-image-sear/kejaocbebojdmebagkjghljkeefgimdj),
  [Search by Image](https://chromewebstore.google.com/detail/search-by-image/cnojnbdhbhnkbcieeekonklommdnndci),
  [FakeNews Debunker](https://chromewebstore.google.com/detail/fake-news-debunker-by-inv/mhccpoafgdgbhnjfhkcmgknndkeenfhe)
- Geolocation assist: [Picarta](https://picarta.ai/)
- EXIF/metadata: [ExifTool](https://exiftool.org/) `[INSTALL: apt install libimage-exiftool-perl]`,
  [Jeffrey's Viewer](http://exif.regex.info/exif.cgi), EXIF Viewer Pro extension
- Foreground: signs, license plates, clothing, vegetation, weather
- Background: landmarks, unique buildings, mountains, water, infrastructure
- Map markings: flora/fauna regions, seasonal indicators (snow, foliage, daylight)
- Trial and error: Google Street View, Bing Streetside, Yandex Panorama;
  [Overpass Turbo](https://overpass-turbo.eu/) for OSM feature queries; Snap Map
  public stories; Google Earth Studio for timelapse/bearing estimation
- Pull text from image: Google/Yandex OCR, then search text + image together;
  YouTube caption extraction for video keyword/entity search

### Image forensics

- [Forensically](https://29a.ch/photo-forensics/), [FotoForensics](http://fotoforensics.com/),
  [Bellingcat Photo Checker](https://photo-checker.bellingcat.com/),
  [Sensity Deepfake Monitor](https://platform.sensity.ai/), [Exposing.ai](https://exposing.ai/)
- C2PA provenance: [Content Credentials Verify](https://verify.contentauthenticity.org/), `c2patool`
- Techniques: Error Level Analysis, metadata examination, clone detection, noise analysis

### Mountain geolocation

- Align image silhouette with 3D models: [PeakVisor](https://peakvisor.com/),
  [Peakfinder](https://www.peakfinder.org/), [PeakLens](https://peaklens.com/) (AR)
- Adjust viewing angle and elevation until ridgelines match

### Fire / environmental identification

- [NASA FIRMS](https://earthdata.nasa.gov/earth-observation-data/near-real-time/firms),
  [Sentinel Hub Playground](https://apps.sentinel-hub.com/sentinel-playground/),
  [Global Forest Watch](https://www.globalforestwatch.org/),
  [Copernicus EFFIS](https://effis.jrc.ec.europa.eu/)

### Track and find planes

- [Apollo ImageHunter](https://imagehunter.apollomapping.com/) — exact satellite image time
- Cross-reference capture moment with [FlightRadar24](https://www.flightradar24.com/) and
  [ADS-B Exchange](https://www.adsbexchange.com/) (unfiltered); verify airframe features

## Video Analysis

- Context: signs/banners/billboards, architecture, road markings, license plates,
  clothing, local customs; search snippets on YouTube/TikTok/X
- Metadata: [YouTube Data Viewer](https://citizenevidence.amnestyusa.org/) (upload date +
  thumbnails), ExifTool on downloaded files `[INSTALL]`
- Platform-specific:
  - TikTok/Instagram: APIs churn — prefer official exports; 1-4h sampling cadence for
    fast-moving topics; fixed persona; capture logs
  - Bluesky (AT Protocol): resolve handles via
    `https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=<handle>` → DID;
    full identity doc at `https://plc.directory/<did>` (handle history, PDS endpoint);
    live firehose at [Firesky](https://firesky.tv/); analytics at
    [SkyView](https://bsky.jazco.dev/); archive early (deletion + handle migration);
    check selected labelers; PDS self-hosting affects data custody
  - Mastodon/Fediverse: instance choice = jurisdiction + moderation + logging;
    WebFinger discovery `https://<instance>/.well-known/webfinger?resource=acct:<user>@<instance>`;
    [FediSearch](https://fedisearch.skorpil.cz/); instance stats via
    [Fediverse Observer](https://fediverse.observer/); follower graphs public by default;
    archive ActivityPub JSON-LD (`id`, `published`, `content`, `attributedTo`);
    deletions propagate asynchronously — check caches/relays
- Auditory clues: languages/dialects, background noise (train horns, call to prayer,
  wildlife); [Audacity](https://www.audacityteam.org/) `[INSTALL: snap install audacity]`,
  [Sonic Visualiser](https://www.sonicvisualiser.org/) spectrograms; Shazam/SoundHound
  for music; [SoundCMD](https://soundcmd.com/) crowd-sourced matching
- Key-frame extraction: FFmpeg `[INSTALL: apt install ffmpeg]` or VLC; regular intervals
  or on scene change; stitch panning frames into panoramas; FFmpeg `deshake` or Blender
  VSE for stabilization; prefer original upload (no re-encode) to keep metadata/audio
- Decode platform snowflakes (Discord, Twitter/X) to infer server-side timestamps

## Chronolocation and Time Analysis

### Shadow analysis

- Measure shadow length + direction; identify casting objects (poles, buildings)
- Solar elevation from object height vs shadow length; azimuth from direction
- Tools: [SunCalc](https://www.suncalc.org/), [ShadeMap](https://shademap.app/) (3D),
  Bellingcat Shadow-Finder, NOAA Solar Calculator
- Use UTC consistently across notes and screenshots; cross-check base imagery with
  OSM map-compare and EOX cloudless layers

### Astronomical calculations

- Night images: identify stars/constellations/moon phase → simulate sky for date+time
- [Stellarium](https://stellarium.org/) `[INSTALL: apt install stellarium]`,
  [MoonCalc](https://www.mooncalc.org/), SkyMap (mobile)

### Satellite imagery time

- Google Earth Pro historical slider; [Sentinel Hub EO Browser](https://apps.sentinel-hub.com/eo-browser/)
  (Sentinel-2, Landsat 8) with timelapse
- Record coordinates in WKT; hash cached tilesets where feasible for reproducibility

## Threat Actor Investigation

### Actor-centric workflow

- Scoping: define the actor hypothesis (APT28/29, Turla, Sandworm; APT10/41, Mustang
  Panda, Volt Typhoon); collect seed reports from CERTs/vendors; extract IOCs + TTPs
- Indicator harvesting: domains, IPs, hashes, JA3/JA4, user-agents; normalize,
  de-duplicate, validate via passive DNS/CT logs/sandboxes
- Infrastructure mapping: CT logs (SANs, issuer, serials), shared hosting, nameserver
  reuse, registrar accounts, HTML/page fingerprints; enrich with ASN/WHOIS history,
  RPKI/ROA status, hosting relationships
- Artifact profiling: PE/ELF metadata (PDB paths, compile timestamps, Rich headers,
  code-signing certs); cluster with SSDEEP/TLSH; YARA + sandbox near-matches
- Social/procurement pivots: developer handles, code snippets, theses, job posts,
  procurement records implying capability or mandate
- Falsification: weigh each linkage (weak/medium/strong); document alternatives;
  never single-source attribution; map TTPs to MITRE ATT&CK with exact citations

### Attribution discipline

- Separate capability from intent and sponsorship; avoid mirror-imaging
- Rule of three: ≥3 independent weak signals, or 1 strong + 1 weak, before asserting
  linkage
- Prefer durable pivots (registrar accounts, code-signing reuse, build-path idioms)
  over ephemeral ones (resolving IPs)
- Mark confidence (low/medium/high); distinguish correlation from control

### Russia-specific pivots

- Corporate/people: EGRUL/EGRIP extracts (captcha-gated), Rusprofile, Kontur.Focus
- Procurement: `zakupki.gov.ru` tenders/contractors; regional portals; grant listings
- Jobs: `hh.ru` for roles, tech stacks, office locations
- Infrastructure: `whois.tcinet.ru`; registrar/nserver patterns; RU-center usage
- Platforms: VKontakte, Odnoklassniki, Rutube, regional news; search Russian +
  transliterations; Telegram channel/admin/cross-post analysis

### China-specific pivots

- Corporate/people: `gsxt.gov.cn` national registry; Tianyancha/Qichacha (freemium)
- ICP filings: `beian.miit.gov.cn` links domains to legal entities via USCC
- Infrastructure: CNNIC WHOIS; Aliyun/Tencent/Huawei Cloud footprints; registrar patterns
- Platforms: Weibo, WeChat Official Accounts (`weixin.sogou.com`), Zhihu, Bilibili,
  Douyin, Xiaohongshu; search Chinese + Pinyin

### Infrastructure & internet measurement

- IP→ASN mapping: HE BGP Toolkit, RIPEstat, BGPView; observe peering ecosystems
- CT logs (crt.sh) for cert reuse and issuance cadence; pivot on subjects/issuers/serials
- URLScan captures for HTML fingerprints, favicon mmh3 hashes, script hashes (clustering)
- Passive DNS over time (SecurityTrails PDNS, DNSDB) for subdomain churn/staging

## People & Social Media Investigation

- Username enumeration: [WhatsMyName](https://whatsmyname.app/),
  [NameCheckup](https://namecheckup.com/), [Sherlock](https://github.com/sherlock-project/sherlock) `[INSTALL]`
- Face search: [PimEyes](https://pimeyes.com/) `[UPSTREAM-REF: consent laws apply]`,
  [Exposing.ai](https://exposing.ai/), Azure Face API `[UPSTREAM-REF: compliance-gated]`
- Graph/content: [Maltego](https://www.maltego.com/), [snscrape](https://github.com/JustAnotherArchivist/snscrape) `[INSTALL]`,
  [SocialBlade](https://socialblade.com/); Bluesky/Mastodon instance explorers + handle
  resolvers for Fediverse pivots

## Infrastructure OSINT

- IP/domain discovery: [Shodan](https://www.shodan.io/) `[UPSTREAM-REF: API key]`,
  [Censys](https://censys.io/) `[UPSTREAM-REF: API key]`, [Onyphe](https://www.onyphe.io/),
  [DNSDB](https://www.farsightsecurity.com/solutions/dnsdb/)
- Certificates/passive DNS: [crt.sh](https://crt.sh/) `[LOCAL via curl]`,
  [SecurityTrails](https://securitytrails.com/) `[UPSTREAM-REF: API key]`
- Malware/artifact workflow: static triage (SHA-256, strings, import tables, PDB path,
  Rich header; VT/Malpedia hints — never rely on AV labels alone) → dynamic sandbox
  (ANY.RUN, Hybrid Analysis, CAPE, Tria.ge: network IOCs, mutexes, drops, C2 patterns)
  → clustering (SSDEEP/TLSH, YARA, config schemas, protocol quirks) → reporting
  (STIX 2.1 IOCs, ATT&CK technique IDs, reproduction steps)
- Telegram: TGStat/Telemetr/Combot for channel growth, overlaps, forwarding graphs;
  export channels with Telegram Desktop preserving message IDs, UTC timestamps, media hashes
- WeChat: Official Accounts via `weixin.sogou.com`; archive articles (PNG + WARC);
  capture `__biz` IDs; expect link rot — archive early

## Automation & Case Management

- [Hunchly](https://www.hunch.ly/) — browser evidence capture
- [Kasm Workspaces](https://kasmweb.com/) — OSINT-ready disposable workspaces
- [ArchiveBox](https://archivebox.io/) — self-hosted web archiver `[INSTALL: pipx install archivebox]`
- [SingleFileZ](https://github.com/gildas-lormeau/SingleFileZ) — single-file page capture

## Synthetic Media Verification

- [Sensity AI](https://sensity.ai/), [Hive Moderation](https://hivemoderation.com/),
  [Reality Defender](https://realitydefender.com/) `[UPSTREAM-REF: commercial]`
- Academic/free: [DeepFake-o-meter](https://deepfakeometer.cs.ipf.mpg.de/)

## Reporting conventions

- JSONL log per case: `{"run_id", "ts"(UTC), "tool"+"version", "artifact", "sha256", "next"}`
- Correlation: cross-check every claim across ≥2 independent sources before asserting
- This skill is methodology for AUTHORIZED investigations — pair with
  `offensive-osint` for the tool catalog and `penetration-testing` for full engagements

---

## Attribution

Ported from [SnailSploit/Claude-Red](https://github.com/SnailSploit/Claude-Red)
(`Skills/recon/offensive-osint-methodology`), Apache-2.0 licensed. Methodology
preserved; Claude-specific mechanics rewritten for OSA's builtin tools.

Part of the offensive skill library — see also `offensive-osint` for the tool
catalog and `penetration-testing` for the full-engagement workflow.