---
name: constant-time-compare
type: security-knowledge
description: "Canonical rules for comparing credentials, MACs, signatures, digests, and any other secret-adjacent value in constant time. Referenced by the triager, fixer, and reviewer role cards."
---

# Constant-time comparison

Comparing credentials, HMACs, signatures, digests, session tokens, or any other attacker-adjacent value with a **variable-time** comparison leaks the value over the network: the attacker measures response time, binary-searches one byte at a time, and recovers the secret. This is not a theoretical class — it is the root cause of Keyczar (2009), Xbox 360 boot ROM (2007), Java 1.4 `String.equals` timing attack, GitHub Enterprise webhook signature bypasses, and many others.

**The hard rule, verbatim for any auditor:**

> When fixing or evaluating a comparison of a credential, MAC, signature, digest, session token, CSRF token, password hash, API key, or any other secret-derived value: use the language's constant-time primitive. Never `==`, `===`, `!=`, `!==`, `.equals()`, `strcmp`, `memcmp`, `Arrays.equals`, `_.isEqual`, or a byte-by-byte loop with early exit. If the code **already** uses a constant-time primitive, the finding is almost always a false positive — do not "fix" it by replacing the safe primitive with equality.

## Safe primitives per language

| Language / runtime | Use                                                                 | Notes                                                                                        |
|---|---|---|
| Node.js (>=6.6)    | `crypto.timingSafeEqual(a, b)`                                      | Requires equal-length Buffers. For unequal inputs, first reject on length mismatch outside the compare. |
| Browser / WebCrypto| `safe-compare` npm, `buffer-equal-constant-time` npm                | WebCrypto `SubtleCrypto` does not expose a constant-time compare; use a vetted library.      |
| Python (stdlib)    | `hmac.compare_digest(a, b)` or `secrets.compare_digest(a, b)`       | Both sides must be the same type (str or bytes).                                             |
| Go (stdlib)        | `subtle.ConstantTimeCompare(a, b []byte) int` from `crypto/subtle`  | Returns 1 for equal, 0 otherwise. Also `ConstantTimeEq`, `ConstantTimeByteEq`.               |
| Java (7+)          | `MessageDigest.isEqual(byte[], byte[])`                             | Became constant-time in Java 7. Earlier versions were NOT safe — check JDK version.          |
| Kotlin             | `MessageDigest.isEqual(a, b)` (same as Java)                        | Kotlin `==` on ByteArray delegates to `Arrays.equals`, which is NOT constant-time.           |
| Ruby (stdlib)      | `OpenSSL.fixed_length_secure_compare(a, b)` (2.4+)                  | Requires equal length; raises otherwise.                                                     |
| Ruby (Rails)       | `ActiveSupport::SecurityUtils.secure_compare(a, b)`                 | Handles length mismatch by first comparing hashes of both values.                            |
| Rust               | `constant_time_eq::constant_time_eq(a, b)` or `subtle::ConstantTimeEq` | `subtle::Choice` from the `subtle` crate is the idiomatic primitive for composition.       |
| C / C++            | `CRYPTO_memcmp` (OpenSSL), `consttime_memequal` (NetBSD), `timingsafe_bcmp` (OpenBSD) | Plain `memcmp`/`bcmp`/`strcmp` are NOT constant-time and must not be used on secrets.      |
| .NET (5+)          | `CryptographicOperations.FixedTimeEquals(a, b)`                     | Requires equal length.                                                                       |
| PHP (>=5.6)        | `hash_equals($known, $user_input)`                                  | Argument order matters for some profiling tools but not for correctness.                     |
| Elixir             | `Plug.Crypto.secure_compare/2`                                      | Available via `:plug_crypto` dep.                                                            |
| Erlang             | `crypto:hash_equals/2` (OTP 25+)                                    | In older OTP use `:crypto.exor/2` + byte accumulator.                                        |

## Unsafe patterns to reject on sight

These are the shapes the model tends to emit when "fixing" an auth finding. **All of them are wrong when applied to credential-shaped data.**

```javascript
// JS / TS — all unsafe on tokens / signatures / hashes
if (providedToken === storedToken) { ... }
if (providedToken == storedToken) { ... }
if (providedToken !== storedToken) { ... }
return sig1.equals(sig2);                 // Buffer.equals is NOT constant-time
return _.isEqual(providedMac, expected);  // lodash isEqual is NOT constant-time
for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }  // early exit = timing leak
```

```python
# Python — all unsafe on tokens / signatures / hashes
if provided_token == stored_token: ...
if provided_token != stored_token: ...
# byte-by-byte with early exit — unsafe
for x, y in zip(a, b):
    if x != y: return False
```

```go
// Go — all unsafe on credentials
if bytes.Equal(provided, stored) { ... }  // bytes.Equal is NOT constant-time
if string(providedMac) == string(expected) { ... }
```

```java
// Java — all unsafe on credentials
if (providedHash.equals(storedHash)) { ... }         // String.equals: short-circuits on length
if (Arrays.equals(providedBytes, storedBytes)) { ... } // NOT constant-time
```

```ruby
# Ruby — unsafe
return provided_token == stored_token
```

```c
/* C — all unsafe on credentials */
if (memcmp(provided, stored, n) == 0) { ... }
if (strcmp(provided, stored) == 0) { ... }
```

## Triager guidance

- If the finding's `description` claims a timing attack on a line that **already** uses one of the safe primitives above, the finding is almost certainly a **false positive**. The scanner LLM does not always know these are safe. Verify by reading the line.
- If the code uses `==` / `.equals()` / `memcmp` / `bytes.Equal` on a credential-shaped variable, confirm as a real timing attack. Note in triage reasoning that the fixer must use the safe primitive; do **not** suggest "validate length first" or "hash then compare" as the fix — those do not stop the timing leak on the comparison itself.

## Fixer guidance

- When writing the fix, locate the right primitive from the table above for the language you are editing. Do not invent one. Do not call it "timing-safe compare" and silently implement it with `===`.
- If the only available constant-time primitive for the ecosystem is a library (e.g. `safe-compare` npm, `subtle` Rust crate), add the dependency using whatever dependency manager the project already uses. Do not hand-roll a constant-time compare in one line — there are published implementations that have been audited.
- If you find yourself about to emit `===`, `.equals(`, `strcmp`, or a byte-by-byte loop on a variable named `*password*`, `*token*`, `*hmac*`, `*signature*`, `*mac*`, `*digest*`, `*auth*`, `*session*`, `*cookie*`, `*csrf*`, `*credential*`, `*nonce*`, `*otp*`, `*bearer*`, `*apikey*`, `*api_key*`, `*pin_hash*`, `*pin_code*`: **STOP**. That is the anti-pattern. Use the language's safe primitive instead. The programmatic guard `guard_no_timing_unsafe_regression` will refuse the commit anyway.

## Reviewer guidance

- On any PR touching auth, HMAC, signature verification, or session handling: verify the diff does not replace a safe primitive with `==` / `.equals()` / `memcmp` / byte-by-byte. This is the single highest-yield check.
- If the diff **removes** a call to a known safe primitive without adding one back (possibly re-named), that is a regression regardless of what else the diff does. Request changes.

## Related failure modes

The same "popular ≠ safe" pattern recurs across other security-critical primitives. As sibling rules land in this directory, they apply the same way:

- PRNGs: `Math.random()` / `random.random()` / `rand()` for tokens or keys is wrong; use `crypto.randomBytes` / `secrets.token_*` / `/dev/urandom`-backed primitives.
- Deserialisation: `pickle.load` / `yaml.load` / `JSON.parse` with a reviver on user-controlled data.
- SQL: string concatenation / template interpolation; use parameterised queries.
- Path handling: check-then-use; resolve-and-contain instead.
- XML: default entity expansion / external DTDs enabled.

Each of these has the same failure mode under AI-assisted fixes: the model emits the **popular** idiom and mistakes it for the **secure** one. Codify the rule, teach the triager the safe primitives, and let the programmatic guard refuse the regression.
