# Query precompilation acceptance

Run from the repository with the Kex compiler being developed:

```sh
KEX=/path/to/kex sh script/check-precompiled-queries.sh
```

This is a narrow acceptance test for generating SQL at compile time while
binding parameters at runtime. It requires neither an ODBC driver nor a
running database. CI runs it alongside the ordinary specs.

The fixture declares its table in an ordinary function and places the query
recipe in `compiled do`. The table is available during evaluation of that
recipe, but the value emitted into the calling function is only a
`Harmat.Odbc.Statement`: literal SQL and a list containing the caller's
`userId`. No schema constant is exported or embedded in the calling function.

The test checks the generated Core Erlang for `query/1` and `deleteQuery/1`:

- The exact SQL is `SELECT id, email FROM users WHERE id = ?`.
- The parameter list contains the runtime variable `UserId`.
- No function call, application, or primitive operation remains in that
  function. Merely producing the right SQL at runtime would fail this check.
- A second query with a runtime `LIMIT` retains its runtime fallback.
- The delete contains literal `DELETE FROM users WHERE id = ?`, binds the
  runtime `UserId`, and makes no SQL builder call.

It then runs the fixture on both the tree walker and BEAM, checking two
parameter values, two limits, and the delete. A second fixture checks fixed
INSERT and UPDATE SQL in Core Erlang and executes each with two different
text and integer parameter sets on BEAM. The write fixture uses BEAM because
the current text conversion path calls `BEAM.erlang`. Builder functions may
still be emitted as fallbacks elsewhere; the assertion concerns the executed
query paths.

## What this does not establish

This is not yet transparent precompilation of arbitrary fluent queries.
The fixture uses the ordinary typed `column == userId` operator. It still
uses an explicit compiled recipe, rather than automatically precompiling
every fluent query in an application.

There is no guarantee here for every insert or update: a runtime map can
still require runtime SQL generation. Dynamic `IN` lists and database-server
prepared-statement caching are also outside this check.
