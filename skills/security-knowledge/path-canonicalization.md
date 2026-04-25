---
name: path-canonicalization
type: security-knowledge
description: "Canonical rule for handling user-supplied filesystem paths. Resolve to canonical form first, then check containment within an allowed root. Never check-then-use, never naive blacklists, never `../` filtering."
---

# Path canonicalisation

When a path component comes from input — a filename in a download URL, a key in a static-file lookup, a relative path in a config — the danger is that the path can escape the directory you intended (`..`, absolute paths, symlinks, Windows alternate-stream syntax, NUL bytes, Unicode normalisation tricks). The wrong fix is "filter dangerous patterns": every blacklist gets bypassed by a representation the author didn't think of (`....//`, URL-encoded `%2e%2e`, encoded-twice, NTFS `8.3` short names, symlink that resolves to outside the root).

The right fix is **resolve first, contain second**: take the path, fully canonicalise it (resolve `..`, `.`, symlinks, normalise unicode), then verify the result is a prefix of the allowed root. If it isn't, reject.

**The hard rule, verbatim for any auditor:**

> Any filesystem path that combines a fixed root with a user-supplied component must (1) be fully resolved (canonical form including symlink resolution where the OS allows it), and (2) be verified to lie strictly inside the intended root, before any open / read / write / stat / unlink / list call. Never inspect the input string for dangerous patterns and pass through the original; the input as a string is meaningless once the OS resolves it. Reject paths that resolve outside the root rather than truncating.

## Safe primitives per language

| Language | Resolve                                                 | Contain                                                |
|---|---|---|
| Node.js  | `path.resolve(root, input)` then `fs.realpathSync(...)` for the resolved file's parent | `resolved.startsWith(rootResolved + path.sep)`         |
| Browser  | (server-side concern; do not do this in the browser)    | n/a                                                    |
| Python   | `(Path(root) / input).resolve()` (Python 3.6+) or `os.path.realpath(os.path.join(root, input))` | `resolved.is_relative_to(Path(root).resolve())` (3.9+), or check `os.path.commonpath([root_resolved, resolved]) == root_resolved` |
| Go       | `filepath.Abs(filepath.Join(root, input))` then `filepath.EvalSymlinks` | `strings.HasPrefix(resolved, rootResolved + string(filepath.Separator))` |
| Java     | `Paths.get(root, input).toRealPath()` or `.toAbsolutePath().normalize()` if symlinks irrelevant | `resolved.startsWith(rootResolved)` (note: `Path.startsWith` checks path components, not strings — preferable) |
| Ruby     | `File.expand_path(input, root)` then `File.realpath(...)` | `resolved.start_with?(File.realpath(root) + File::SEPARATOR)` |
| Rust     | `Path::new(root).join(input).canonicalize()`             | `resolved.starts_with(root.canonicalize()?)`           |
| C / C++  | `realpath(path, NULL)` (POSIX), `GetFinalPathNameByHandle` (Windows) | `strncmp(resolved, root, strlen(root)) == 0` AND next char is `/` |
| .NET     | `Path.GetFullPath(Path.Combine(root, input))`            | `resolved.StartsWith(rootFullPath + Path.DirectorySeparatorChar)` |

**Note**: `startsWith` string comparison must include the trailing separator, otherwise `/var/data/users` matches `/var/data/users-evil`. Use a path-aware containment helper if the language has one.

## Unsafe patterns to reject

```javascript
// JS / TS
const filename = req.query.file;                      // user input
fs.readFile(`./uploads/${filename}`, ...);            // unsafe — `..` escapes
fs.readFile(path.join('./uploads', filename), ...);   // still unsafe — `..` resolves outside
if (filename.includes('..')) return 403;              // bypassed by `....//`, %2e%2e, encoded, etc.
```

```python
# Python
fname = request.args['file']
open(f'/var/uploads/{fname}', 'rb')                   # unsafe
open(os.path.join('/var/uploads', fname), 'rb')       # unsafe — `..` resolves through join
if '..' in fname: abort(403)                           # bypassable
```

```go
// Go
input := r.URL.Query().Get("file")
os.Open(filepath.Join("/var/uploads", input))          // join doesn't resolve; absolute paths in input override the root
```

```java
// Java
String name = req.getParameter("file");
File f = new File("/var/uploads/" + name);             // unsafe
new FileInputStream(new File("/var/uploads", name));   // unsafe
```

```ruby
# Ruby
fname = params[:file]
File.read("/var/uploads/#{fname}")                     # unsafe
File.read(File.join('/var/uploads', fname))            # unsafe — relative `..` escapes
```

```php
// PHP
$file = $_GET['file'];
file_get_contents("/var/uploads/$file");                // unsafe
file_get_contents("/var/uploads/" . basename($file));   // basename strips dir, but Windows alt-streams (`name:stream`) and NUL bytes still bypass for some sinks
```

## Triager guidance

| What you see | Verdict |
|---|---|
| Path built from `<root> + <input>` and passed directly to `open` / `readFile` / `fs.createReadStream` / `unlink` / `lstat` / `File`-constructor / `os.Open` / similar with no canonicalisation step in between | `confirmed` — path traversal, severity depends on what's reachable. Critical if it can read arbitrary files; high if it can only read inside one user's directory; medium if read-only and limited. |
| Path filtered with `if '..' in input` / `input.replace('..','')` / `path.normalize` only / regex check before joining | `confirmed` — string-level filtering does not stop encoded / double-encoded / unicode / symlink escapes. |
| Code calls `realpath` / `Path.resolve` / `toRealPath` / `filepath.EvalSymlinks` / `Path.GetFullPath` and then containment-checks against the root | `false_positive` — safe pattern. Verify the containment check uses a path-aware comparison or includes the trailing separator. |
| Path comes from a hardcoded enum / allowlist (`if name not in ['report.pdf','data.csv']: abort`) | `false_positive` — allowlist is structurally safe. |

## Fixer guidance

- Resolve the path to canonical form using the language's `realpath` / `resolve` / `toRealPath` / `EvalSymlinks` primitive. Then check the resolved path is inside the intended root.
- The containment check must include the directory separator: `resolved.startsWith(root + '/')`, not just `resolved.startsWith(root)`. Otherwise sibling directories with the same prefix succeed.
- Reject (e.g. 403 / throw) when the resolved path is outside the root. Don't truncate or fall through to a default — silent fallthrough hides errors.
- For uploads: combine with extension allowlist, content-type sniffing, and the "save with a generated UUID, not the user filename" pattern. Fixing path traversal alone doesn't fix arbitrary-extension upload.
- Do **not** fix by adding `.replace('..','')` or `.replace(/\\.\\./g,'')` — those filter the source string but the OS will resolve `....//` or `%2e%2e` or symlinks all the same. The fix is canonicalise + contain.

## Reviewer guidance

- **Reject** if the diff filters dangerous substrings (`..`, `\\`, `/`) from the input and concatenates the cleaned string. That's the wrong shape; the rule is canonicalise + contain.
- **Reject** if the containment check is a substring/prefix string match without the trailing separator (path comparison must be path-aware or include `+ '/'`).
- **Approve** when the diff resolves to canonical form and verifies containment against a resolved root. Watch for the resolved-root caching — if the root is a symlink that gets re-pointed, a stale cached resolution becomes wrong.
- Symlinks inside the upload directory: if the application allows users to create symlinks, the canonicalisation step is moot — the user can point a symlink at `/etc/passwd` and the resolve will follow it. The fix in that case is "don't follow symlinks" (`O_NOFOLLOW`, `lstat` instead of `stat`).

## Programmatic guard

There is no programmatic guard for this rule in the current release. Detecting "path built from input and passed to file open without resolving" reliably via regex is hard — distinguishing a hardcoded filename from a user-controlled one needs taint tracking, which is out of scope for the line-level guards. The rule is enforced at the LLM layer; for stricter automated checking, use a SAST tool with taint analysis (semgrep with custom rules, CodeQL).
