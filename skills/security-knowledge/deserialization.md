---
name: deserialization
type: security-knowledge
description: "Canonical rule for deserialising untrusted data. Never `pickle.load`, `yaml.load`, `Marshal.load`, `unserialize`, `JSON.parse` with a reviver, or any 'native object' deserialiser on untrusted input. Use a safe parser that produces only data, not code."
---

# Untrusted-data deserialisation

A general-purpose deserialiser turns input bytes into language objects. If the format includes "construct an object of class X" instructions and the deserialiser honours them on untrusted input, the input is code: an attacker controls which classes get instantiated, which constructors run, and what methods get called on those constructors. This is a primary RCE class — the original Java RMI deserialisation chain, Python pickle gadgets, Ruby Marshal, PHP unserialize POP chains, even YAML's `!!python/object` tag.

The fix is structural: deserialise into **plain data** (dicts, lists, strings, numbers, booleans, null), then validate, then construct your domain objects yourself with explicit constructor arguments. That breaks the "input is code" pathway because the parser literally cannot produce arbitrary objects.

**The hard rule, verbatim for any auditor:**

> When deserialising input that came from a request body, file upload, environment, message queue, database row written by another process, or any other source you do not fully control: use a parser that produces only plain data. Never `pickle.load`, `pickle.loads`, `cPickle.*`, `yaml.load` (without `Loader=SafeLoader`), `yaml.unsafe_load`, `Marshal.load`, `marshal.loads`, `phps unserialize`, `node-serialize.unserialize`, Java `ObjectInputStream.readObject`, .NET `BinaryFormatter`, `Ruby Marshal.load`, `eval`-on-input. Construct domain objects manually after validating the parsed plain data.

## Safe primitives per language

| Language | Use                                                        | Notes                                                       |
|---|---|---|
| Python   | `json.loads`, `yaml.safe_load`, `tomllib.loads`            | `pickle.*`, `marshal.*`, `yaml.load` are unsafe on untrusted input. |
| Node.js / Browser | `JSON.parse(text)` (no reviver), `csv-parse`, language-typed parsers | Avoid `eval`, `Function(text)`, `vm.runInThisContext`. `JSON.parse(text, reviver)` is safe ONLY if the reviver does not call non-JSON code on the parsed value. |
| Java     | Jackson with default-typing OFF (`mapper.deactivateDefaultTyping()`), Gson, JSON-B | Never `ObjectInputStream.readObject` on untrusted input. Never enable Jackson `enableDefaultTyping` on untrusted input. |
| .NET     | `System.Text.Json.JsonSerializer.Deserialize`, `Newtonsoft.Json` with `TypeNameHandling.None` | `BinaryFormatter`, `NetDataContractSerializer`, `SoapFormatter` are deprecated and unsafe; remove them. `TypeNameHandling.All` / `Auto` re-enables the unsafe path. |
| Ruby     | `JSON.parse(text)`, `YAML.safe_load(text)`, `Psych.safe_load(text)` | `Marshal.load`, `YAML.load` (pre-Ruby-3.1 default), `Oj.load(... mode: :object)` are unsafe. |
| PHP      | `json_decode`, `(array)json_decode($x, true)`              | `unserialize($_POST[...])`, `unserialize($_COOKIE[...])` are unsafe. |
| Go       | `encoding/json.Unmarshal`, `encoding/xml.Unmarshal`        | `encoding/gob` should not be used on untrusted input.        |
| Rust     | `serde_json::from_str`, `serde_yaml::from_str`             | These produce structured data only.                          |
| Elixir   | `Jason.decode`, `:erlang.binary_to_term(bin, [:safe])` (note: `:safe` does NOT prevent atom exhaustion or large-tuple DoS) | `:erlang.binary_to_term` without `:safe` deserialises into arbitrary atoms / functions and is unsafe on untrusted input. |

## Unsafe patterns to reject

```python
# Python — every one of these is RCE on untrusted input
import pickle, yaml, marshal
data = pickle.loads(request.body)
data = pickle.load(open('cache.pkl','rb'))   # if cache.pkl path is influenced by input
data = yaml.load(request.form['config'])     # without Loader=SafeLoader
data = yaml.unsafe_load(request.form['x'])
data = marshal.loads(request.body)
exec(request.body)                           # not deserialisation per se, but in the same family
```

```javascript
// JS / TS — eval/Function/vm and unsafe-reviver patterns
const x = eval(request.body);
const fn = new Function(request.body);
const obj = JSON.parse(request.body, (k, v) => eval(v));    // reviver running input
const obj = require('node-serialize').unserialize(request.body);
require('vm').runInThisContext(request.body);
```

```java
// Java — ObjectInputStream on untrusted input is the textbook RCE
ObjectInputStream ois = new ObjectInputStream(req.getInputStream());
Object o = ois.readObject();    // unsafe — even with whitelisting it's brittle
// also unsafe: Jackson default-typing on untrusted input
ObjectMapper m = new ObjectMapper();
m.enableDefaultTyping();        // global default-typing = remote RCE
```

```csharp
// .NET — BinaryFormatter is deprecated for exactly this reason
var bf = new BinaryFormatter();
var obj = bf.Deserialize(req.Body);
// also unsafe:
JsonConvert.DeserializeObject(payload, new JsonSerializerSettings {
    TypeNameHandling = TypeNameHandling.All  // remote type instantiation
});
```

```ruby
# Ruby — Marshal.load is RCE; old YAML.load is RCE
Marshal.load(request.body)
YAML.load(request.body)                          # pre-3.1 default; in 3.1+ defaults are safer but still call YAML.safe_load explicitly
Oj.load(request.body, mode: :object)             # object-mode = RCE class
```

```php
// PHP — unserialize on user input is the classic POP-chain RCE
$obj = unserialize($_POST['data']);
$obj = unserialize($_COOKIE['session']);
```

```go
// Go — gob.Decode on untrusted input is unsafe
import "encoding/gob"
gob.NewDecoder(req.Body).Decode(&out)
```

## Triager guidance

| What you see | Verdict |
|---|---|
| `pickle.load` / `pickle.loads` / `cPickle.*` / `marshal.load` on input from request / file path under input control / env var / message body | `confirmed` — **critical** unless source is provably trusted (e.g. a checked-in fixture file). |
| `yaml.load` without `Loader=SafeLoader`, or `yaml.unsafe_load`, on untrusted input | `confirmed` — **critical**. |
| `Marshal.load` (Ruby), `unserialize` (PHP), `ObjectInputStream.readObject` (Java), `BinaryFormatter.Deserialize` (.NET) on untrusted input | `confirmed` — **critical**. |
| `JSON.parse(input, reviver)` where the reviver evaluates the value through `eval` / `new Function` / `setTimeout(value, 0)` | `confirmed` — the reviver is the unsafe path; the parser itself is fine. |
| Code uses safe variant (`json.loads`, `yaml.safe_load`, `JSON.parse(input)` no reviver, `JsonSerializer.Deserialize` with no type-name handling) | `false_positive` — safe pattern. |
| Pickle / Marshal / unserialize on data **the same process just produced and signed/MAC'd** with a key the attacker doesn't have | `false_positive` IF the MAC is verified before deserialisation AND the MAC uses constant-time comparison (see hash-then-compare.md). Note both conditions in your reasoning. |

## Fixer guidance

- Replace the unsafe deserialiser with the language's safe data parser from the table.
- After parsing, **explicitly construct** your domain objects from the plain data. Validate types and ranges at the boundary; reject anything you don't recognise. The construction step is the security boundary, not the parser.
- For YAML specifically: `yaml.safe_load(...)` in Python; `YAML.safe_load(...)` in Ruby; `yaml.SafeLoader` in PyYAML config. Never `yaml.load(...)` with the default loader.
- For Java / Jackson: do **not** call `enableDefaultTyping`. If polymorphic deserialisation is required, use `@JsonTypeInfo` on a small allowlist of types and configure a `PolymorphicTypeValidator` with explicit allowed names.
- For .NET: replace `BinaryFormatter` with `System.Text.Json` or Newtonsoft + `TypeNameHandling.None`. If migration is too large, mark the finding `failed` with a "needs human design" note — `BinaryFormatter` removal is a real refactor.
- Don't use `eval` / `Function` / `runInThisContext` / `exec` on input even with "validation" — validation logic is an arms race against the parser; the safe parser is the answer.

## Reviewer guidance

- **Reject** any diff that retains the unsafe deserialiser or replaces it with a different unsafe variant (e.g. swapping `pickle.loads` for `marshal.loads`).
- **Reject** if the fix adds `enableDefaultTyping` / `TypeNameHandling.All` / `mode: :object` / a custom unsafe reviver — those are reintroducing the same exposure.
- **Approve** when the diff uses the safe parser AND a validation step constructs domain objects from the parsed plain data. The validation step is what makes the fix complete.
- Watch for "I added a validator that walks the parsed-pickle tree" — this is the wrong direction; pickle's load already executed code. Validation must happen **after** `safe_load`, not in a tree-walk over `pickle.load`'s output.

## Programmatic guard

`guard_no_unsafe_deserialize` in `scripts/lib/guards.sh` flags any diff that adds a call to `pickle.load(s?)`, `cPickle.load(s?)`, `marshal.load(s?)`, `yaml.load(` (without `Loader=SafeLoader` on the same line), `yaml.unsafe_load(`, `Marshal.load(`, `unserialize(`, `ObjectInputStream(`, `BinaryFormatter(`, or `node-serialize.unserialize(`. Pattern is line-local; if a legitimate use exists (e.g. a fixture-loading script), restructure or document and the rule will still flag.
