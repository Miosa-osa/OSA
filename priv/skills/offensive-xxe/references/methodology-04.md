#### Apigee Edge

```xml
<!-- XMLThreatProtection policy -->
<XMLThreatProtection name="XML-Threat-Protection">
  <Source>request</Source>
  <StructureLimits>
    <NodeDepth>10</NodeDepth>
    <AttributeCountPerElement>5</AttributeCountPerElement>
    <NamespaceCountPerElement>3</NamespaceCountPerElement>
    <ChildCount includeComment="true" includeElement="true" includeProcessingInstruction="true" includeText="true">10</ChildCount>
  </StructureLimits>
  <ValueLimits>
    <Text>1000</Text>
    <Attribute>100</Attribute>
    <NamespaceURI>100</NamespaceURI>
    <Comment>500</Comment>
    <ProcessingInstructionData>500</ProcessingInstructionData>
  </ValueLimits>
</XMLThreatProtection>
```

#### Nginx + ModSecurity

```nginx
# ModSecurity rules for XXE
SecRule REQUEST_BODY "@rx <!ENTITY" \
    "id:1000,phase:2,deny,status:403,msg:'XXE Attack Detected'"

SecRule REQUEST_BODY "@rx <!DOCTYPE.*\[" \
    "id:1001,phase:2,deny,status:403,msg:'DTD Declaration Blocked'"
```

### Parser default hardening (2024-2025)

- **libxml2 ≥ 2.13**: `XML_PARSE_NO_XXE` disables all external entity resolution by default.
- **Python ≥ 3.13**: standard `xml.*` modules forbid external entities; enable only via `feature_external_ges`.
- **.NET 8**: project templates set `XmlReaderSettings.DtdProcessing = Prohibit`.
- **Java 22**: `XMLConstants.FEATURE_SECURE_PROCESSING` is enabled and `external-general-entities` is `false`.

### Cloud-metadata nuance

AWS IMDSv2 now requires a session token. To exploit metadata via XXE you must first obtain a token with  
`PUT /latest/api/token` and then pass it in the `X-aws-ec2-metadata-token` header of subsequent requests.

### Secure Parser Configuration (practical snippets)

```java
// Java (SAX/StAX/DOM)
DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
dbf.setFeature("http://xml.org/sax/features/external-general-entities", false);
dbf.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
dbf.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
dbf.setXIncludeAware(false);
dbf.setExpandEntityReferences(false);
```

```python
# Python – prefer defusedxml
from defusedxml.ElementTree import fromstring
fromstring(xml_data)
```

```csharp
// .NET
var settings = new XmlReaderSettings
{
    DtdProcessing = DtdProcessing.Prohibit,
    XmlResolver = null
};
using var reader = XmlReader.Create(stream, settings);
```

```go
// Go – standard encoding/xml does not resolve external entities
// but avoid streaming untrusted data into custom resolvers
type Safe struct{ }
```

```php
// PHP – libxml
$old = libxml_disable_entity_loader(true);
$xml = simplexml_load_string($data, "SimpleXMLElement", LIBXML_NONET | LIBXML_NOENT);
libxml_disable_entity_loader($old);
```

---

## Attribution

Ported from [SnailSploit/Claude-Red](https://github.com/SnailSploit/Claude-Red)
(`Skills/*/offensive-xxe`), Apache-2.0 licensed. Methodology preserved; Claude-specific
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
