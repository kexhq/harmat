# Harmat

A database layer for [Kex](https://github.com/kexhq/kex): tables declared in
Kex, queries built in the way Drizzle writes them, and migrations that are
data — ordered by what follows what, and rolled back without anybody writing
a "down".

```kex
using Harmat.Database, as: Database

Database.select([:id, :email])
  .from(users)
  .where(owner.eq("ada"))
  .orderBy(descending: [:created_at])
  .limit(10)
  .all
```

It talks to a database through ODBC and writes only standard SQL, so the
same application runs on a SQLite file in development and on PostgreSQL in
production: the connection string is the whole difference. Its specs run on
both.

## Installing

In your package's `package.kex`:

```kex
tey("harmat", git: "https://github.com/kexhq/harmat", branch: "main")
```

then `tey install`. Harmat needs Kex 0.4.0-rc.1 or newer, and at run time
unixODBC with a driver for your database (see [Connecting](#connecting)).

## Tables

A table is declared once, with the words a migration uses for its columns:

```kex
using Harmat.Table, as: Table

let users = Table.define :users do |t|
  t.text(:id, primaryKey: true)
  t.text(:email)
  t.text(:owner)
  t.text(:role, default: "member", oneOf: ["member", "admin"])
  t.bigint(:credit, default: 0)
  t.boolean(:active, default: true)
end
```

| Column | Stored as | Options |
| --- | --- | --- |
| `t.text` | `TEXT` | `primaryKey:`, `nullable:`, `default:`, `oneOf:` |
| `t.bigint` | `BIGINT` | `primaryKey:`, `nullable:`, `default:` |
| `t.int` | `INTEGER` | `primaryKey:`, `nullable:`, `default:` |
| `t.boolean` | `BOOLEAN` | `nullable:`, `default:` |
| `t.serial` | `INTEGER …` per database, assigned by it | always the primary key; no `default:` |

A column is `NOT NULL` unless `nullable: true`; `default: :null` is a `NULL`
default; `oneOf:` becomes a `CHECK`.

A serial column is always the primary key and has no `default:`: the database
assigns it, so leave it out of `values` and `set` and reach it with
`wholeColumn` like any integer column. It is the one thing Harmat spells per
database — `AUTOINCREMENT` on SQLite, `GENERATED ALWAYS AS IDENTITY` on
PostgreSQL — read off the connection string (an unknown driver gets the
SQLite spelling); everything else is the same SQL on both.

Columns are reached as typed handles, which is what conditions are asked of:

```kex
let email = users.textColumn(:email)     # compares to a String
let owner = users.textColumn(:owner)
let credit = users.wholeColumn(:credit)  # compares to an Integer

email.eq("ada@example.com")   # a condition
credit.eq("five")             # does not build
```

## Queries

`using Harmat.Database, as: Database`, and start from the module. Nothing is
sent until a query is finished with `all`, `first` or `run`.

```kex
# Rows: each a map from column name to text.
Database.select().from(users).all
Database.select([:id, :email]).from(users).orderBy([:email]).limit(10).all

# One row, or None.
Database.select().from(users).where(email.eq(address)).first

# Several conditions all have to hold.
Database.select().from(users)
  .where(owner.eq("ada"))
  .where(credit.eq(5))
  .orderBy([:email], descending: [:credit])
  .all

# Writes answer with the number of rows they changed.
Database.insert(users).values({id: id, email: address, credit: 5}).run
Database.update(users).set({credit: 6}).where(email.eq(address)).run
Database.delete(users).where(email.eq(address)).run
```

| Finished with | Answers |
| --- | --- |
| `all` | `Result<[{String: String}], String>` |
| `first` | `Result<{String: String}?, String>` |
| `run` | `Result<Integer, String>` |

`values` and `set` take a map of column name to value. Each value is
written the way its declared column stores it, and a name the table does
not declare is an error from Harmat rather than one from the database.

### Confined statements

`Database.within(condition)` starts statements that all carry a condition —
reads, updates and deletes alike. What is confined to one owner cannot reach
another's rows, whatever the query built on it goes on to say:

```kex
let hers = Database.within(owner.eq("ada"))
hers.update(users).set({credit: 1}).where(email.eq(address)).run
# UPDATE users SET credit = CAST(? AS BIGINT) WHERE owner = ? AND email = ?
```

### SQL, as SQL

For what the builder has no word for there is the `sql` tag. A literal is
checked when the program is built — it has to start with a statement
keyword, with its parentheses and quotes balanced — and a `${}` hole in a
`sql$` literal becomes a bound parameter, never text:

```kex
using Harmat.Sql, only: [sql]

sql`SELECT name FROM users WHERE id = ?`
sql$`UPDATE users SET age = ${age} WHERE id = ${id}`
```

## Connecting

Harmat reaches a database through Erlang's `odbc`, and a connection is an
ODBC connection string and nothing else:

```kex
Harmat.Odbc.connect("Driver=/opt/homebrew/lib/libsqlite3odbc.dylib;Database=db/development.sqlite3")
Harmat.Odbc.connect("Driver={PostgreSQL Unicode};Server=db;Port=5432;Database=app;Uid=app;Pwd=…")
```

| | macOS (Homebrew) | Debian / Ubuntu |
| --- | --- | --- |
| unixODBC | `brew install unixodbc` | `apt-get install unixodbc` |
| SQLite driver | `brew install sqliteodbc` | `apt-get install libsqliteodbc` |
| PostgreSQL driver | `brew install psqlodbc` | `apt-get install odbc-postgresql` |

The Debian packages register their drivers by name, `SQLite3` and
`PostgreSQL Unicode`; Homebrew's do not, so there a driver is named by its
path (`/opt/homebrew/lib/libsqlite3odbc.dylib`,
`/opt/homebrew/lib/psqlodbcw.so`).

An Erlang packaged without the ODBC port program (Homebrew's is) reports
`port_program_executable_not_found`. `script/setup-odbc.sh` builds one into a
directory of yours, and `Harmat.Odbc.sideload(directory)` puts it on the code
path before the first `connect`:

```sh
sh script/setup-odbc.sh db/odbc
```

### The database is a capability

A query names no database and none is handed around. Everything a builder
sends goes through `Harmat.Connection`, which an application installs for
the region of code that serves:

```kex
with Harmat.Connection = Harmat.Database.Direct { connection: connection } do
  Database.select().from(users).all
end
```

Outside any `with` there is no database, and a query answers
`Error("no database connected")`.

`Direct` is for code running in the process that opened the connection. An
ODBC connection answers only that process, so an application that serves
many processes installs a record of its own that asks the owner instead:

```kex
record StoreConnection do
  store : Server<Store>
end

make StoreConnection, implement: Harmat.Connection do
  foul run(statement: Harmat.Odbc.Statement) -> Result<Integer, String> do
    …   # INSERT, UPDATE, DELETE: the number of rows changed
  end

  foul ask(statement: Harmat.Odbc.Statement) -> Result<[[String]], String> do
    …   # SELECT: the rows, each as its cells in column order
  end
end
```

Three things follow from it being a capability:

- A replacement reaches the processes spawned inside the region, and the
  blocks and function references *written* inside it. Routes that name their
  actions have to be built inside the `with`, not only served there.
- Reads and writes are separate members, so a record can send `ask` to a
  replica and `run` to a primary without a query changing.
- A spec installs a record that notes statements instead of running them. A
  stand-in needs at least one field: a record with none cannot be asked a
  method.

## Migrations

A migration is a value: a name, what it follows, and its operations.

```kex
using Harmat.Migration, as: Migration
using Harmat.Migration, only: [createTable, addColumn, addIndex]

let change = Migration.define :create_users do
  createTable(:users) do |t|
    t.text(:id, primaryKey: true)
    t.text(:email)
  end
  addIndex(:users, [:email], unique: true)
end

let change = Migration.define :add_user_names, follows: :create_users do
  addColumn(:users) do |t| t.text(:name, default: "") end
end
```

| Operation | Undone by |
| --- | --- |
| `createTable(:t) do \|t\| ... end` | dropping it |
| `dropTable(:t) do \|t\| ... end` | creating it again, as the block says it was |
| `dropTable(:t)` | nothing: it cannot be rolled back |
| `addColumn(:t) do \|t\| ... end` | removing the column |
| `removeColumn(:t) do \|t\| ... end` | adding it back, as the block says it was |
| `addIndex(:t, [:a, :b], unique: true)` | dropping the index |
| `removeIndex(:t, [:a, :b])` | creating it again |
| ``execute(sql`…`, undo: sql`…`)`` | running `undo:`; without one, nothing |

`execute` runs a literal's text as written and binds no values: write them
into the statement.

### Order is a graph

Order comes from `follows`, never from file names or timestamps. On one
branch that is a chain. When two branches each add a migration, both follow
the same one, and after the merge the history has two heads — which
`ordered` reports by name instead of interleaving them silently. It is
settled by saying so, without touching either branch's migration:

```kex
let change = Migration.merge(:merge_names_and_avatars, [:add_user_names, :add_avatars])
```

What a database has run is a set of names, kept in a `schema_migrations`
table, so one that already ran one branch simply runs the other's next.

### Running them

```kex
Harmat.Migration.migrate(connection, migrations)       # the names it ran
Harmat.Migration.rollback(connection, migrations, 2)   # the newest two, undone
```

Both take an open `Harmat.Odbc` connection and every migration of the
application, in any order, and answer `Result<[String], String>`.

Nobody writes a "down": `rollback` works out the opposite of each operation
and runs them last to first. Every migration it is about to undo is checked
for reversibility before the first is touched.

| | |
| --- | --- |
| `Migration.ordered(all)` | the migrations parents-first, or what is wrong with the history |
| `Migration.head(all)` | the one head: what the next migration should follow |
| `Migration.irreversible(all)` | what could not be rolled back, for a spec to refuse before it is merged |
| `Migration.statements(step)`, `undoing(step)` | the SQL a migration runs, and the SQL that undoes it |

### Declared tables are held to the migrations

`Harmat.Table.drift(tables, migrations)` replays the migration history into
the tables it produces and lists every way they differ from the ones
declared: a column declared but never migrated, a default changed in one
place only. An application that refuses to start on a non-empty answer
finds out at boot, not from an SQL error on a later request.

### A generator for the next one

Harmat is a Tey plugin. From an application that depends on it,

```sh
tey generate harmat:migration --name add_avatars --force
```

writes `db/migrate/N0006_add_avatars.kex` — numbered after the last,
following the current head — and adds it to the list in
`db/migrations.kex`. (`--force`, because that list already exists and is
rewritten.)

## What it does not do

- A condition is an equality, `column.eq(value)`. There is no `<`, `LIKE`,
  `IN` or `OR` in the builder, and no joins: reach for `sql`.
- Rows come back as maps of text, not as records. Turning one into a record
  is the caller's. A `NULL` reads as `""`.
- There are no transactions.
- `Harmat.Query`, a builder whose chains are evaluated while the program is
  compiled, cannot be used from another package yet
  ([kexhq/kex#444](https://github.com/kexhq/kex/issues/444)). It is why the
  `sql` tag lives in `Harmat.Sql`.

## Modules

| | |
| --- | --- |
| `Harmat.Database` | the query builder: `select`, `insert`, `update`, `delete`, `within` |
| `Harmat.Confined` | what `within` gives: statements that all carry a condition |
| `Harmat.Connection` | the capability every statement is sent through |
| `Harmat.Table`, `Harmat.Column` | declaring tables and columns; `drift` |
| `Harmat.Schema` | column handles and conditions |
| `Harmat.Migration` | migrations: the DSL, the history, `migrate` and `rollback` |
| `Harmat.Sql` | the `sql` tagged literal |
| `Harmat.Odbc` | the ODBC boundary: `connect`, `sideload`, `execute`, `query` |
| `Harmat.Query` | the compile-time builder (see above) |

## Developing

```sh
tey install
tey build
tey test
```

The specs that need a database make SQLite files, through Homebrew's driver
unless told otherwise:

| Variable | |
| --- | --- |
| `HARMAT_SPEC_DRIVER` | the SQLite ODBC driver: a path, or a name unixODBC knows (`SQLite3` on Debian) |
| `HARMAT_SPEC_DSN` | a whole connection string, to run a spec against another database |

```sh
HARMAT_SPEC_DSN="Driver={PostgreSQL Unicode};Server=localhost;Database=harmat_spec;Uid=…;Pwd=…" \
  tey test spec/database.spec.kex
```

Run one spec file per database that way: each makes the tables it needs and
leaves them. CI (`.github/workflows/ci.yml`) runs everything on SQLite, and
the database and migration specs on PostgreSQL 17 as well.

## License

Harmat is licensed under the GNU Lesser General Public License, version 3
or (at your option) any later version (`LGPL-3.0-or-later`).
See [COPYING.LESSER](COPYING.LESSER) and [COPYING](COPYING) for the license terms.
