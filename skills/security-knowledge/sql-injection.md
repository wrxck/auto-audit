---
name: sql-injection
type: security-knowledge
description: "Canonical rule for building SQL queries that include user-supplied values. Use parameterised queries (`?`, `:param`, `$1`); never string concatenation, template interpolation, or hand-rolled escaping. Referenced by the triager, fixer, and reviewer role cards."
---

# SQL injection

User-supplied values must reach the database through the query API's **parameter** channel, not through string substitution into the query text. Any code path where input is concatenated, interpolated, or escaped-by-hand into a SQL string is broken — escaping logic gets bypassed by character set tricks, second-order injection, stored unicode quirks, or driver-specific quoting differences. Parameterised queries close the channel completely because the value is sent separately from the SQL and never participates in lexing.

This is the most-exploited web vulnerability class in history (decades of CVE evidence). The fix is structurally simple: every database driver supports parameter binding. Use it everywhere, every time.

**The hard rule, verbatim for any auditor:**

> Every SQL query that includes a value sourced from a function argument, request parameter, environment variable, file content, database row, or any other input must use the database driver's parameter-binding mechanism. The query string passed to `execute` / `query` / `prepareStatement` / `Db.query` must contain only literal SQL plus parameter placeholders (`?`, `$1`, `:name`). User-supplied values must travel as a separate argument. String concatenation, `f"..."`-style interpolation, `${}` template literals, `String.format`, `printf`, manual escaping libraries, and "safe" wrappers are all banned for query construction. Identifiers (table / column names) that come from input require explicit allowlist validation — they cannot be parameterised.

## Safe patterns per language

| Language / driver | Safe                                                            | Notes                                                     |
|---|---|---|
| Node.js `mysql2` / `pg` | `db.query('SELECT * FROM users WHERE id = ?', [id])`, `db.query('SELECT * FROM users WHERE id = $1', [id])` | Always pass the values array as the second argument.       |
| Node.js Knex / Drizzle / Prisma | Use the query builder's column/value methods (`.where('id', id)`); avoid `.raw('... ${id}')` | Builders parameterise. `raw` interpolation undoes that.    |
| Python `sqlite3` / `psycopg2` / `mysql.connector` | `cur.execute('SELECT * FROM users WHERE id = ?', (id,))`, `cur.execute('SELECT * FROM users WHERE id = %s', (id,))` | The `%s` is the driver placeholder, **not** Python `%` formatting. |
| Python SQLAlchemy   | `session.execute(text('... :id'), {'id': id})`, ORM filters       | Avoid `text(f'... {id}')`.                                 |
| Go `database/sql`   | `db.Query("SELECT * FROM users WHERE id = ?", id)` (MySQL/SQLite), `db.Query("SELECT * FROM users WHERE id = $1", id)` (Postgres) | The driver handles binding.                                |
| Java JDBC           | `PreparedStatement ps = c.prepareStatement("SELECT * FROM users WHERE id = ?"); ps.setLong(1, id);` | Never use `Statement` for queries that include input.      |
| Ruby `ActiveRecord` | `User.where(id: id)`, `User.where('email = ?', email)`            | Avoid `User.where("email = '#{email}'")`.                  |
| Rust `sqlx`         | `sqlx::query!("SELECT * FROM users WHERE id = ?", id)`            | The macro is compile-time-checked.                         |
| C# `System.Data.SqlClient` / EF | `cmd.CommandText = "SELECT * FROM users WHERE id = @id"; cmd.Parameters.AddWithValue("@id", id);` | LINQ-to-Entities also parameterises.                       |
| PHP `PDO`           | `$st = $pdo->prepare('SELECT * FROM users WHERE id = :id'); $st->execute([':id' => $id]);` | Avoid `mysqli_real_escape_string` + concat.                |
| Elixir `Ecto`       | `from(u in User, where: u.id == ^id)`, `Repo.query("...", [id])`  | The `^` interpolation is parameter binding, not string.    |

## Unsafe patterns to reject

```javascript
// JS / TS — all unsafe
db.query(`SELECT * FROM users WHERE email = '${email}'`);
db.query("SELECT * FROM users WHERE id = " + id);
knex.raw(`UPDATE users SET name = '${name}' WHERE id = ${id}`);
```

```python
# Python — all unsafe
cur.execute(f"SELECT * FROM users WHERE email = '{email}'")
cur.execute("SELECT * FROM users WHERE id = %s" % id)
cur.execute("SELECT * FROM users WHERE id = " + str(id))
session.execute(text(f"DELETE FROM users WHERE id = {id}"))
```

```go
// Go — fmt.Sprintf into the query is unsafe
db.Query(fmt.Sprintf("SELECT * FROM users WHERE id = %d", id))
db.Exec("DELETE FROM users WHERE name = '" + name + "'")
```

```java
// Java — Statement + concat is the textbook SQLi
Statement s = c.createStatement();
s.executeQuery("SELECT * FROM users WHERE email = '" + email + "'");
String q = String.format("SELECT * FROM users WHERE id = %d", id); // still unsafe under JDBC.Statement
```

```ruby
# Ruby — interpolation in where() is unsafe
User.where("email = '#{params[:email]}'")
User.find_by_sql("SELECT * FROM users WHERE id = #{id}")
```

```php
// PHP — concat / mysqli_query without prepare is unsafe
$pdo->query("SELECT * FROM users WHERE id = $id");
mysqli_query($conn, "SELECT * FROM users WHERE email = '$email'");
```

## Triager guidance

| What you see | Verdict |
|---|---|
| Query string built by concatenation / interpolation / `String.format` / `f"..."` / template literal containing a value sourced from input | `confirmed` — **critical** unless reachability is genuinely impossible. |
| Query passed through a hand-rolled escape function (`mysql_escape_string`, `addslashes`, custom `escape()`) and then concatenated | `confirmed` — escaping is bypassable; parameterise instead. |
| Query uses driver placeholders (`?`, `$1`, `:name`) and values array | `false_positive` — safe pattern. |
| Identifier (table / column name) interpolated into query | Look at validation: if the name is checked against an allowlist (e.g. `if name not in ALLOWED_COLUMNS: raise`) `false_positive`; otherwise `confirmed` — identifiers cannot be parameterised, only allowlisted. |
| `LIKE` query with user input + `%` interpolation | `confirmed` if the wildcard escapes (`\\%`, `\\_`) are missing — separately a SQLi-adjacent class. |

## Fixer guidance

- Convert to parameter binding using the driver's native placeholder. Move the value into the values array; the SQL string becomes a literal with `?` / `$1` / `:name` / `@name` markers.
- Identifier injection (table / column name from input): build an allowlist of permitted identifiers and validate before substitution. Never escape a column name and concatenate.
- ORM users: prefer the ORM's column-typed methods (`.where('id', id)`, `User.where(id: id)`, `Repo.where(u.id == ^id)`) over `raw`/`text` escape hatches. If `raw` is unavoidable, parameterise inside it.
- `LIKE` queries with user input: parameterise the value, then ensure the value-side escapes `%` and `_` if the user shouldn't be able to use them as wildcards.
- Do **not** add a hand-rolled escape function as the fix. The library has parameter binding; use it.

## Reviewer guidance

- **Reject** any query string that ends up as the first argument to `execute` / `query` / `prepare` / `prepareStatement` and includes any non-literal expression. The whole point of parameter binding is that the SQL string is constant; if the diff introduces concat or interpolation into that string, the fix is not a fix.
- **Approve** when the placeholder pattern matches the driver and the values are passed as the parameters argument.
- Special case: dynamic ORDER BY / dynamic table name — these are legitimately not parameterisable. The fix must show explicit allowlist validation. Approve when the validation is sound; reject when it's a regex-cleanup ("only allow alphanumeric") which is not equivalent to allowlisting.

## Programmatic guard

There is no programmatic guard for SQLi in the current release. Detecting "SQL string built by concat with input" via regex hits an unbounded false-positive rate (any string containing the word `SELECT` would trip; many legitimate strings contain SELECT). The rule is enforced at the LLM layer only — triager / fixer / reviewer cards explicitly call out this class. If you want stricter enforcement on a specific repo, a dedicated linter (sqlfluff, semgrep, language-specific SAST) is the right tool, not the auto-audit guard.
