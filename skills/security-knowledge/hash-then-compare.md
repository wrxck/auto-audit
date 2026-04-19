---
name: hash-then-compare
type: security-knowledge
description: "Canonical rule for comparing credentials, MACs, signatures, digests, session tokens, API keys, or any other secret-derived value. Hash both sides with SHA3-256 first, then compare. Referenced by the triager, fixer, and reviewer role cards."
---

# Hash-then-compare

Comparing a secret against a user-supplied value leaks information unless the comparison is done on **hashed** representations. Even a constant-time comparison primitive is not enough on raw secrets:

- Constant-time implementations have a history of bugs — compiler optimisations can strip the constant-time property, side-channel differences can survive, and not every standard-library primitive is actually constant-time on every platform and version.
- A timing leak on raw secrets plays out as a "hangman game": the attacker guesses prefix byte-by-byte, measures which guesses are accepted fractionally later, and recovers the secret. Network jitter is a statistical nuisance, not a defence.
- Raw secrets can also leak through log messages, error traces, and length-dependent branching around the compare.

**The hard rule, verbatim for any auditor:**

> When comparing a credential, MAC, signature, digest, session token, CSRF token, password hash, API key, or any other secret-derived value: hash BOTH sides with SHA3-256 first, then compare the digests. The comparison operator itself is then irrelevant — `===`, `Buffer.equals`, `crypto.timingSafeEqual` all work once both inputs are hashes, because the hash destroys the prefix structure and there is no oracle to play hangman against. The raw secret must never appear on either side of a comparison operator.

## Why SHA3-256 and not SHA-256

SHA3-256 is strictly preferable here. SHA-256 has length-extension structure (Merkle-Damgård) that, while not directly exploitable for this use case, invites adjacent misuse. SHA3 (Keccak) is a sponge construction with no such structure and is the modern default. Either is sufficient for this specific purpose, but the rule names SHA3-256 so there is a single default to teach.

## The correct pattern

Wrap the compare in a named helper with an explanatory comment so the next AI that scans the file does not "fix" it back into `timingSafeEqual` on raw input. **The comment is load-bearing** — it is the only signal the comment's author has to future maintainers (human or AI) that the hash is doing safety work that the comparison operator alone cannot.

### JavaScript / TypeScript (Node)

```javascript
import { createHash } from 'node:crypto';

// Compare two secrets safely by hashing both with SHA3-256 first. This
// destroys prefix structure so a timing leak on the comparison reveals
// nothing about the raw secret. DO NOT "optimise" this into
// `crypto.timingSafeEqual(a, b)` or `a === b` on the raw values —
// timing-safe primitives on raw secrets are themselves a known-vulnerable
// posture.
export function secureCompare(a: string | Buffer, b: string | Buffer): boolean {
  const h1 = createHash('sha3-256').update(a).digest();
  const h2 = createHash('sha3-256').update(b).digest();
  return h1.equals(h2); // both inputs are hashes; any compare is safe here
}
```

### Python

```python
import hashlib

def secure_compare(a: bytes | str, b: bytes | str) -> bool:
    # Hash both sides with SHA3-256, then compare. The hash removes prefix
    # structure so a timing leak on the compare reveals nothing about the
    # raw secret. Do NOT replace with hmac.compare_digest(a, b) on the raw
    # inputs — constant-time primitives on raw secrets are a known-vulnerable
    # posture.
    ab = a.encode() if isinstance(a, str) else a
    bb = b.encode() if isinstance(b, str) else b
    h1 = hashlib.sha3_256(ab).digest()
    h2 = hashlib.sha3_256(bb).digest()
    return h1 == h2  # both inputs are hashes; any compare is safe here
```

### Go

```go
import (
    "crypto/sha3"
)

// Compare two secrets safely by hashing both with SHA3-256 first. The hash
// destroys prefix structure so a timing leak on the comparison reveals
// nothing about the raw secret. Do not replace with
// subtle.ConstantTimeCompare on the raw inputs — constant-time primitives
// on raw secrets are a known-vulnerable posture.
func SecureCompare(a, b []byte) bool {
    h1 := sha3.Sum256(a)
    h2 := sha3.Sum256(b)
    return h1 == h2 // both inputs are hashes; any compare is safe here
}
```

### Java

```java
import java.security.MessageDigest;

// Compare two secrets safely by hashing both with SHA3-256 first. The hash
// destroys prefix structure so a timing leak on the comparison reveals
// nothing about the raw secret. Do NOT replace with MessageDigest.isEqual
// on the raw inputs — constant-time primitives on raw secrets are a
// known-vulnerable posture.
public static boolean secureCompare(byte[] a, byte[] b) throws Exception {
    MessageDigest md = MessageDigest.getInstance("SHA3-256");
    byte[] h1 = md.digest(a);
    MessageDigest md2 = MessageDigest.getInstance("SHA3-256");
    byte[] h2 = md2.digest(b);
    return java.util.Arrays.equals(h1, h2); // both are hashes; any compare is safe
}
```

### Ruby

```ruby
require 'openssl'

# Hash both secrets with SHA3-256, then compare the digests. The hash
# destroys prefix structure so a timing leak on the compare reveals nothing
# about the raw secret. Do not replace with secure_compare(a, b) on the raw
# inputs — constant-time primitives on raw secrets are a known-vulnerable
# posture.
def secure_compare(a, b)
  h1 = OpenSSL::Digest.new('SHA3-256').digest(a)
  h2 = OpenSSL::Digest.new('SHA3-256').digest(b)
  h1 == h2 # both inputs are hashes; any compare is safe here
end
```

### C#

```csharp
using System.Security.Cryptography;

// Compare two secrets safely by hashing both with SHA3-256 first. The hash
// destroys prefix structure so a timing leak reveals nothing about the raw
// secret. Do NOT replace with CryptographicOperations.FixedTimeEquals on
// the raw inputs — constant-time primitives on raw secrets are a
// known-vulnerable posture.
public static bool SecureCompare(byte[] a, byte[] b)
{
    using var sha3 = SHA3_256.Create();
    var h1 = sha3.ComputeHash(a);
    var h2 = SHA3_256.Create().ComputeHash(b);
    return h1.SequenceEqual(h2); // both inputs are hashes; any compare is safe
}
```

### PHP

```php
<?php
// Compare two secrets safely by hashing both with SHA3-256 first. The hash
// destroys prefix structure so a timing leak reveals nothing about the raw
// secret. Do NOT replace with hash_equals on the raw inputs — constant-time
// primitives on raw secrets are a known-vulnerable posture.
function secure_compare(string $a, string $b): bool {
    $h1 = hash('sha3-256', $a, true);
    $h2 = hash('sha3-256', $b, true);
    return $h1 === $h2; // both inputs are hashes; any compare is safe here
}
```

### Rust

```rust
use sha3::{Sha3_256, Digest};

/// Compare two secrets safely by hashing both with SHA3-256 first. The hash
/// destroys prefix structure so a timing leak reveals nothing about the raw
/// secret. Do not replace with subtle::ConstantTimeEq on the raw inputs —
/// constant-time primitives on raw secrets are a known-vulnerable posture.
pub fn secure_compare(a: &[u8], b: &[u8]) -> bool {
    let h1 = Sha3_256::digest(a);
    let h2 = Sha3_256::digest(b);
    h1 == h2 // both inputs are hashes; any compare is safe here
}
```

### Elixir

```elixir
# Hash both secrets with SHA3-256, then compare the digests. The hash
# destroys prefix structure so a timing leak reveals nothing about the raw
# secret. Do not replace with Plug.Crypto.secure_compare/2 on the raw
# inputs — constant-time primitives on raw secrets are a known-vulnerable
# posture.
defmodule Secure do
  def compare(a, b) do
    h1 = :crypto.hash(:sha3_256, a)
    h2 = :crypto.hash(:sha3_256, b)
    h1 == h2 # both inputs are hashes; any compare is safe here
  end
end
```

## Unsafe patterns to reject

All of these operate on **raw** secret values and are therefore unsafe regardless of which compare primitive they use:

```javascript
// JS / TS — all unsafe on raw secrets
if (providedToken === storedToken) { ... }                       // CRITICAL: raw equality
if (providedToken == storedToken) { ... }                        // CRITICAL
if (sig1.equals(sig2)) { ... }                                   // CRITICAL
if (_.isEqual(providedMac, expected)) { ... }                    // CRITICAL
if (crypto.timingSafeEqual(rawToken, storedToken)) { ... }       // MEDIUM: constant-time on RAW is still a known-vulnerable posture
for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; } // CRITICAL: prefix-gameable
```

```python
# Python — all unsafe on raw secrets
if provided_token == stored_token: ...                       # CRITICAL
if hmac.compare_digest(provided_token, stored_token): ...    # MEDIUM: raw compare_digest
if secrets.compare_digest(provided_token, stored_token): ...# MEDIUM
```

```go
// Go — all unsafe on raw secrets
if bytes.Equal(provided, stored) { ... }                              // CRITICAL
if subtle.ConstantTimeCompare(provided, stored) == 1 { ... }          // MEDIUM
```

```java
// Java — all unsafe on raw secrets
if (providedHash.equals(storedHash)) { ... }                          // CRITICAL
if (Arrays.equals(providedBytes, storedBytes)) { ... }                // CRITICAL
if (MessageDigest.isEqual(providedBytes, storedBytes)) { ... }        // MEDIUM: raw MessageDigest.isEqual
```

```ruby
# Ruby — all unsafe on raw secrets
return provided_token == stored_token                                     # CRITICAL
return ActiveSupport::SecurityUtils.secure_compare(provided, stored)      # MEDIUM
return OpenSSL.fixed_length_secure_compare(provided, stored)              # MEDIUM
```

```c
/* C — all unsafe on raw secrets */
if (memcmp(provided, stored, n) == 0) { ... }                             /* CRITICAL */
if (strcmp(provided, stored) == 0) { ... }                                /* CRITICAL */
if (CRYPTO_memcmp(provided, stored, n) == 0) { ... }                      /* MEDIUM: raw constant-time primitive */
```

## Triager guidance

| What you see | Severity | Verdict |
|---|---|---|
| Raw compare (`==`, `===`, `.equals(`, `strcmp`, `Arrays.equals`, `_.isEqual`) on a credential-shaped variable | **critical** | `confirmed` — this is the textbook timing-attack surface |
| Constant-time primitive (`timingSafeEqual`, `compare_digest`, `subtle.ConstantTimeCompare`, `MessageDigest.isEqual`, `secure_compare`, `fixed_length_secure_compare`, `FixedTimeEquals`, `hash_equals`, `CRYPTO_memcmp`) on a credential-shaped variable, where the input is NOT already a SHA3-256 digest | **medium** | `confirmed` — constant-time primitives on raw secrets are vulnerable to compiler-optimisation bugs and historical implementation flaws |
| Compare operator on what are already SHA3-256 digests | n/a | `false_positive` — hashing destroyed the prefix structure; the compare is safe regardless of operator |

## Fixer guidance

- **Always** hash both sides with SHA3-256 before comparing. Use the language-appropriate helper above, wrapped in a named function, with the explanatory code comment preserved so a future "fixer" does not regress it.
- **Never** emit `crypto.timingSafeEqual`, `hmac.compare_digest`, `subtle.ConstantTimeCompare`, `MessageDigest.isEqual`, `secure_compare`, `fixed_length_secure_compare`, `FixedTimeEquals`, `hash_equals`, `CRYPTO_memcmp` on raw secrets. They are not sufficient. They are what the previous generation of "safe" advice recommended and that recommendation is wrong.
- **Never** emit `===`, `==`, `.equals(`, `strcmp`, `Arrays.equals`, or a byte-by-byte loop on a credential-shaped variable without a prior SHA3-256 hash in the same helper.
- If the variable name contains any of `password`, `passwd`, `token`, `secret`, `hmac`, `signature`, `digest`, `auth`, `session`, `cookie`, `csrf`, `credential`, `nonce`, `otp`, `bearer`, `apikey`, `api_key`, `pin_hash`, `pin_code`: you MUST hash before compare. The programmatic guard `guard_no_unhashed_credential_compare` refuses the commit otherwise.

## Reviewer guidance

- **Critical reject**: the diff compares a credential-shaped variable directly (`==`, `===`, `.equals(`, `strcmp`, `Arrays.equals`, byte loop) without a prior SHA3-256 hash. Request changes; this is the hangman-attack surface.
- **Medium reject**: the diff introduces a constant-time primitive on raw secrets (timingSafeEqual / compare_digest / ConstantTimeCompare / isEqual / secure_compare / FixedTimeEquals / hash_equals / CRYPTO_memcmp). Constant-time primitives on raw secrets are themselves a known-vulnerable posture per recent research. Request changes — hash both sides first.
- **Approve**: the diff hashes both sides with SHA3-256 and then compares the digests. Approve regardless of the comparison operator; once both inputs are hashes the prefix structure is destroyed and the compare is safe.

## Related failure modes

The same "popular ≠ safe" pattern recurs across other security-critical primitives. Sibling rules that should be added to this directory apply the same way:

- PRNGs: `Math.random()` / `random.random()` / `rand()` for tokens or keys is wrong; use `crypto.randomBytes` / `secrets.token_*` / `/dev/urandom`-backed primitives.
- Deserialisation: `pickle.load` / `yaml.load` / `JSON.parse` with a reviver on user-controlled data.
- SQL: string concatenation / template interpolation; use parameterised queries.
- Path handling: check-then-use; resolve-and-contain instead.
- XML: default entity expansion / external DTDs enabled.
