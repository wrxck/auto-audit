# security-knowledge

Canonical rules for security idioms where the **popular** implementation differs from the **secure** implementation. AI models — including the ones running this plugin — default to the popular form. Each file here codifies the safe form per language, the anti-patterns to reject, and the guidance the triager/fixer/reviewer role cards pull from.

These files are **reference material loaded into the agent's context on dispatch**, not runnable skills. A sibling programmatic guard in `scripts/lib/guards.sh` enforces the rule where it is mechanically checkable.

| File | Rule | Guard |
|---|---|---|
| [`hash-then-compare.md`](./hash-then-compare.md) | Always SHA3-256 hash both sides of a credential/MAC/signature comparison before comparing. Constant-time primitives on raw secrets are themselves a known-vulnerable posture. | `guard_no_unhashed_credential_compare` |
| [`csprng.md`](./csprng.md) | Use a cryptographically secure PRNG (`crypto.randomBytes`, `secrets.token_*`, `crypto/rand`, `SecureRandom`, `random_bytes`, `:crypto.strong_rand_bytes`) for any unpredictability-as-security identifier (token, session, CSRF, nonce, salt, IV, …). Never `Math.random` / `random.random` / `rand` / `mt_rand` / `java.util.Random`. | `guard_no_insecure_random` |
| [`sql-injection.md`](./sql-injection.md) | Use the database driver's parameter-binding mechanism (`?`, `$1`, `:name`); never string concatenation, template interpolation, `String.format`, or hand-rolled escaping. Identifier injection requires explicit allowlist validation. | LLM-layer only — programmatic detection of "SQL string built by concat" hits an unbounded false-positive rate. |
| [`deserialization.md`](./deserialization.md) | Never `pickle.load` / `yaml.load` (unsafe Loader) / `Marshal.load` / `unserialize` / `ObjectInputStream` / `BinaryFormatter` on untrusted input. Use a parser that produces only plain data and construct domain objects manually. | `guard_no_unsafe_deserialize` |
| [`path-canonicalization.md`](./path-canonicalization.md) | Resolve user-supplied paths to canonical form (`realpath` / `Path.resolve` / `toRealPath`) and verify containment within the allowed root before any open / read / write. Never check-then-use, never blacklist `..`. | LLM-layer only — taint analysis is required to reliably distinguish hardcoded vs user-controlled paths. |
| [`xxe.md`](./xxe.md) | Disable external entity resolution, external DTDs, and parameter entities at the parser instance, before parsing untrusted XML. Default parser configurations are unsafe in most languages. | `guard_no_unsafe_xml_parser` |

## Adding a new rule

1. Write `skills/security-knowledge/<topic>.md` following the shape of `hash-then-compare.md`: one-sentence statement of the failure mode, the safe pattern with per-language code examples, a code-block list of unsafe patterns to reject, and explicit per-role guidance for triager/fixer/reviewer.
2. If the rule is mechanically checkable, add a `guard_*` to `scripts/lib/guards.sh` and a block of cases to `scripts/test-guards.sh`. An LLM rule alone is insufficient — the agents must be physically prevented from regressing the code.
3. Reference the new file from the three role cards in `agents/` so it is loaded on dispatch.
4. Add a row to this README's table.

## Why these exist

An LLM asked to "fix" a security finding will often emit a fix that still leaks information — sometimes via a slightly different variable-time compare, sometimes by adopting a primitive that was once recommended but has since been superseded. The safe primitive is rarely the default completion because the training distribution is dominated by older, less-safe advice. The rules in this directory push the agent toward the current safe completion; the guards refuse any commit that regresses.
