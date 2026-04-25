---
name: xxe
type: security-knowledge
description: "Canonical rule for parsing XML on untrusted input. Disable external entity resolution, external DTDs, and parameter entities at the parser. Never feed untrusted XML to a default-configured parser."
---

# XML external entity (XXE)

XML's standard processing model includes "external entities" — directives like `<!ENTITY x SYSTEM "file:///etc/passwd">` and `<!DOCTYPE foo SYSTEM "http://attacker/payload.dtd">` that instruct the parser to fetch and inline content from arbitrary URLs at parse time. On most XML libraries this is **on by default**. An attacker who can submit XML to a default-configured parser gets:

- Server-side file disclosure (read any file the process can read).
- Server-side request forgery (the parser fetches attacker-supplied URLs from inside your network).
- Denial-of-service (Billion-Laughs / Quadratic Blowup nested entity expansion).
- In some configurations, RCE via crafted DTDs.

The fix is per-parser: **disable** external entity resolution, external DTDs, and entity expansion at the parser instance, before parsing untrusted input. Most parsers expose a single feature flag for this. The wrong fix is to scan the input for `<!ENTITY` strings — that's bypassable by encoding tricks, alternate DOCTYPE forms, and parameter entities.

**The hard rule, verbatim for any auditor:**

> Any XML parser fed untrusted input must have external entity resolution, external DTD loading, and parameter entities disabled at the parser instance, before the parse call. The settings vary by library; the goal is identical across all of them: the parser must not fetch any URL or expand any entity declared in the input. Default parser configurations are unsafe almost universally.

## Safe primitives per language

| Language / library | Disable                                                                                  |
|---|---|
| Python `lxml`      | Use `defusedxml.lxml` (preferred), or `lxml.etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False)`. |
| Python stdlib `xml.etree.ElementTree` / `xml.dom.minidom` / `xml.sax` | Use `defusedxml` (`defusedxml.ElementTree`, `defusedxml.minidom`, `defusedxml.sax`). The stdlib parsers are unsafe by default and `defusedxml` is the canonical fix. |
| Java JAXP `DocumentBuilderFactory` | `f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);` (preferred — bans DOCTYPE entirely). Otherwise: `f.setFeature("http://xml.org/sax/features/external-general-entities", false); f.setFeature("http://xml.org/sax/features/external-parameter-entities", false); f.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false); f.setXIncludeAware(false); f.setExpandEntityReferences(false);` |
| Java `SAXParserFactory` / `XMLInputFactory` (StAX) | Same feature flags as above. For StAX: `factory.setProperty(XMLInputFactory.SUPPORT_DTD, false); factory.setProperty("javax.xml.stream.isSupportingExternalEntities", false);` |
| .NET `XmlDocument` / `XmlReader` | `XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null }`. For `XmlDocument`, `doc.XmlResolver = null;` AND read via the prohibited-DTD `XmlReader`. |
| Node.js `libxmljs2` | `libxml.parseXml(input, { noent: false, dtdload: false, dtdvalid: false, nonet: true })`. |
| Node.js `fast-xml-parser` | Has no entity expansion; this parser is structurally safer for untrusted input. |
| PHP `libxml`       | `libxml_disable_entity_loader(true);` (deprecated/removed in PHP 8.0; in 8.0+ external entities are off by default but parameter entities still pose a DoS risk — use `LIBXML_NONET \| LIBXML_DTDLOAD \| LIBXML_NOENT`-zero options on parse). |
| Ruby Nokogiri      | `Nokogiri::XML(input) { \|c\| c.options = Nokogiri::XML::ParseOptions::NONET; c.strict; c.nonet }`. Default options DO load network DTDs in some versions — set `NONET` explicitly. |
| Go `encoding/xml`  | The Go stdlib `encoding/xml` does not resolve external entities; default-safe. Validate this if you're using a third-party parser instead. |
| Rust `quick-xml`   | Does not resolve external entities; default-safe. |

## Unsafe patterns to reject

```python
# Python — stdlib parsers default-load external entities
import xml.etree.ElementTree as ET
ET.fromstring(request.body)              # unsafe — use defusedxml.ElementTree.fromstring
import lxml.etree as etree
etree.fromstring(request.body)           # unsafe — default lxml resolves entities and loads DTDs
```

```java
// Java — JAXP defaults are unsafe
DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
DocumentBuilder b = f.newDocumentBuilder();
b.parse(new InputSource(new StringReader(input)));    // unsafe — DOCTYPE allowed by default
SAXParserFactory sf = SAXParserFactory.newInstance();
sf.newSAXParser().parse(input, handler);              // unsafe — same defaults
```

```csharp
// .NET — XmlDocument and XmlReader default-load DTDs in older targets
var doc = new XmlDocument();
doc.LoadXml(userInput);                  // unsafe — needs XmlResolver=null and DtdProcessing.Prohibit
```

```php
// PHP — pre-8.0 default loads external entities
$dom = new DOMDocument();
$dom->loadXML($userInput);               // unsafe in PHP < 8.0 unless libxml_disable_entity_loader(true)
```

```ruby
# Ruby — Nokogiri defaults vary; must set NONET explicitly
Nokogiri::XML(request.body)              # may load network DTDs depending on version
```

## Triager guidance

| What you see | Verdict |
|---|---|
| Untrusted XML parsed with default config of `lxml`, stdlib `xml.*`, JAXP `DocumentBuilderFactory`, SAX, StAX, .NET `XmlDocument`, libxml (PHP < 8.0), Nokogiri without `NONET` | `confirmed` — **critical** if the input is reachable from a network endpoint; **medium** if reachable only from a local file the user already controls. |
| Code uses `defusedxml`, JAXP with `disallow-doctype-decl=true`, .NET with `DtdProcessing=Prohibit` and `XmlResolver=null`, Nokogiri with `NONET`, or a parser that doesn't expand entities at all (`fast-xml-parser`, Go `encoding/xml`, Rust `quick-xml`) | `false_positive` — safe pattern. |
| Code "validates" the XML by string-checking for `<!ENTITY` or `<!DOCTYPE` substrings before parsing | `confirmed` — string filtering is bypassable (encoded entities, alternate DOCTYPE forms, parameter entities); the parser config is the right place to fix. |

## Fixer guidance

- Switch to the safe parser/configuration from the table for the language.
- For Python: replace `xml.etree.ElementTree.fromstring` with `defusedxml.ElementTree.fromstring`. Add `defusedxml` to the project's dependency manifest.
- For Java: prefer the single-line `disallow-doctype-decl=true` if you don't need DOCTYPE at all (most apps don't); otherwise set the four external-entity / external-DTD / parameter-entity / XInclude flags individually.
- For .NET: build an `XmlReaderSettings` with `DtdProcessing.Prohibit` and `XmlResolver = null`, and pass it to `XmlReader.Create(...)`. If using `XmlDocument`, set `doc.XmlResolver = null` AND read via the locked-down `XmlReader`.
- For PHP 8.0+: external entities are off by default but parameter-entity-based DoS is still a risk — pass `LIBXML_NONET` and avoid `LIBXML_NOENT`.
- For Ruby Nokogiri: set `Nokogiri::XML::ParseOptions::NONET` (and `STRICT` if appropriate).
- Don't add a string-level scan for `<!ENTITY` as the fix. The parser's feature flags exist precisely so application code doesn't have to do this.

## Reviewer guidance

- **Reject** if the fix retains a default-configured parser and adds a string-level prefilter.
- **Reject** if the fix sets only some of the JAXP feature flags but not all — particularly the external-parameter-entities flag (a frequent oversight).
- **Approve** when the diff configures the parser instance to disallow DOCTYPE / external entities / external DTDs / parameter entities AND that configured instance is what processes the untrusted input.
- For Python projects: prefer `defusedxml` over hand-configuring `lxml.etree.XMLParser` flags. The `defusedxml` defaults are correct; `lxml` configuration has subtle pitfalls (e.g. `resolve_entities=False` doesn't stop external DTD loading).

## Programmatic guard

`guard_no_unsafe_xml_parser` in `scripts/lib/guards.sh` flags any diff that adds a call to a known unsafe XML parser API without an accompanying safety configuration on a nearby line. Patterns scanned: `xml.etree.ElementTree.fromstring(`, `xml.etree.ElementTree.parse(`, `xml.dom.minidom.parseString(`, `xml.sax.parseString(`, `lxml.etree.fromstring(`, `lxml.etree.parse(`, `DocumentBuilderFactory.newInstance(`, `SAXParserFactory.newInstance(`, `XMLInputFactory.newInstance(`, `new XmlDocument()`, `DOMDocument()` (PHP), `Nokogiri::XML(`. Safety markers scanned for in the same file's added lines: `defusedxml`, `disallow-doctype-decl`, `DtdProcessing.Prohibit`, `XmlResolver = null`, `NONET`, `resolve_entities=False`, `load_dtd=False`. If any unsafe parser appears without any safety marker, the guard dies.
