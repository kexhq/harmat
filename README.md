# Harmat

A database layer for [Kex](https://github.com/kexhq/kex): tables declared in
Kex, queries built in the way Drizzle writes them, and migrations that are
data — ordered by what follows what, and rolled back without anybody writing
a "down".

```kex
using Harmat.Database, as: Database

Database.select([:id, :email])
  .from(users)
  .where(owner == "ada")
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

email == "ada@example.com"   # a condition, not true or false
email != "ada@example.com"
credit >= 5
credit == "five"             # does not build
```

A comparison of a column with a value builds a condition for a `WHERE`:
`==`, `!=`, `<`, `<=`, `>` and `>=`, each taking a value of the column's own
type. Comparing two columns is record equality, as it would be without them.

Conditions join with `||` and `&&`, `&&` binding tighter, as in SQL; several
`where`s all have to hold:

```kex
.where(owner == "ada" || credit > 100)
.where(owner == "ada" || owner == "bob" && credit > 5)
```

Both sides are always part of the condition: nothing is short-circuited.
(A file that only gets its columns from a table's `textColumn` may need
`using Harmat.Schema, only: [Cond]` for `||` to be the condition's —
kexhq/kex#532.)

### What a table is for, and what it belongs to

A table and its columns can say what they are for, a `belongsTo` is a column
that refers to another table, and a `hasMany` names the rows of another
table that refer to this one. They are descriptions: `belongsTo` is a plain
text column to the database, and `hasMany` is not a column at all.

```kex
let members = Table.define :team_members, doc: "Who is in which team" do |t|
  t.text(:id, primaryKey: true)
  t.belongsTo(:team, :teams)
  t.belongsTo(:user, :users, doc: "A person or a bot")
  t.belongsTo(:adder, :users, column: :added_by, default: "")
end

let teams = Table.define :teams do |t|
  t.text(:id, primaryKey: true)
  t.hasMany(:members, :team_members)
end
```

`t.belongsTo(:team, :teams)` is the column `team_id`; `column:` names one
that is not `<name>_id`, and a default of `""` makes the reference optional.
A plain column can refer too, as a migration would write it —
`t.text(:team_id, references: :teams)` — and `belongsTo(…, inverse:
:memberships)` names the other side from this one. A `hasMany` outnames
both; with no name anywhere, the rows are called by the referring table's
name, and `via:` says which column one means when several refer back. A
table that refers to two others joins them: `throughs` lists what a table
has many of through it.
`Harmat.Table.relations(tables)` lists every relationship, and
`belongsTo(tables, table)` and `hasMany(tables, table)` a single table's: what
a diagram, a generator or docs start from. Drift checks that each
reference names a declared table with a primary key, stored the way the
column is, and that each `hasMany` matches exactly one of them.

## Queries

`using Harmat.Database, as: Database`, and start from the module. Nothing is
sent until a query is finished with `all`, `first` or `run`.

```kex
# Rows: each a map from column name to text.
Database.select().from(users).all
Database.select([:id, :email]).from(users).orderBy([:email]).limit(10).all

# One row, or None.
Database.select().from(users).where(email == address).first

# Larger or smaller: <, <=, > and >=, by number or by text.
Database.select().from(users).where(credit >= 5).all

# How many: in all, or for each value of a column.
Database.select().from(users).where(owner == "ada").count      # Ok(2)
Database.select().from(users).countBy(:owner)                  # Ok({"ada": 2, "bob": 1})

# A column among several values; an empty list matches nothing.
Database.select().from(users).where(email.in(addresses)).all

# Several conditions all have to hold.
Database.select().from(users)
  .where(owner == "ada")
  .where(credit == 5)
  .orderBy([:email], descending: [:credit])
  .all

# Writes answer with the number of rows they changed.
Database.insert(users).values({id: id, email: address, credit: 5}).run
Database.update(users).set({credit: 6}).where(email == address).run
Database.delete(users).where(email == address).run
```

Every statement `Database` runs is timed and told to `Harmat.Logger`, a
capability that tells nobody unless a program installs one. Installing
`Harmat.Log.Console` prints each, as Rails does in development: the table,
how long it took, the SQL highlighted by kind, the values (anything that
looks like a password hash or a token's digest as `[FILTERED]`) and what
came of it.

```kex
with Harmat.Logger = Harmat.Log.Console { shown?: development } do
  site.start(host, port)
end
```

```
  users (0.4ms)  SELECT id, email FROM users WHERE email = ?  ["ada@example.com"]  1 row
```

| Finished with | Answers |
| --- | --- |
| `all` | `Result<[{String: String}], String>` |
| `first` | `Result<{String: String}?, String>` |
| `run` | `Result<Integer, String>` |

`values` and `set` take a map of column name to value. Each value is
written the way its declared column stores it, and a name the table does
not declare is an error from Harmat rather than one from the database.

### The everyday ones, shorter

Each of these is still exactly one query, sent where it is written, and
never something that queries again later:

```kex
Database.all(users)                                     # every row
Database.find(users, "u1")                              # the row with this primary key, or None
Database.findBy(users, {email: address})                # the first row with these values
Database.exists?(users, {email: address})               # whether there is one
Database.select().from(users).by({owner: "ada"}).pluck(:email)
Database.insertAll(memberships, [first, second])        # several rows, stopping at a failure
Database.belongingTo(posts, users, ids, via: :author)   # a has-many for many rows at once
```

`by` narrows any select, update or delete by a map of column to value, each
written the way its column stores it, so the plain equalities need no
`where`. `belongingTo` gives back the rows of `posts` that refer to any of
`ids`, grouped by the key each refers to, in one `IN` query; the column is
the one `posts` declares, and `via:` picks one by name or column when
several refer to the same table.

### Records instead of rows

A query answers with records when it is given their type:

```kex
Database.select().from(users).by({owner: "ada"}).all(as: User)   # Result<[User], String>
Database.select().from(users).where(email == address).first(as: User)
Database.all(users, as: User)
Database.find(users, id, as: User)
Database.findBy(users, {email: address}, as: User)
Database.insert(users).record(user, extra: {created_at: now}).run
```

A field is filled from the column of its name in snake case — `ownerId` from
`owner_id`, `admin?` from `admin` — read as its type: text, a number, a flag
(`TRUE`, `true`, `t`, `1` or `yes`), an option (`""` is `None`), a list of text
separated by commas, or a constructor of a sum type (`GroupChat` from
`group_chat`). A field whose type is an alias is read as text, since Kex
does not yet say what an alias stands for (kexhq/kex#530). What a row does
not say, or cannot, the field's declared default stands for, and a required
field left unfilled is an error; `renamed:` maps a field to a column of
another name. `record` goes the other way: each field into the column of its
name, where the table has one, and `extra:` for the rest. A constructor
written anywhere — `values`, `set`, `by` — is stored by that same snake-case
name, and `Harmat.Column.choices(Type.of(Kind))` lists them for a column's
`oneOf:`, so the CHECK follows the type.

There is no decoder to write per record: the record's own fields, as Kex
knows them at run time, say what to read.

### Confined statements

`Database.within(condition)` starts statements that all carry a condition —
reads, updates and deletes alike. What is confined to one owner cannot reach
another's rows, whatever the query built on it goes on to say:

```kex
let hers = Database.within(owner == "ada")
hers.update(users).set({credit: 1}).where(email == address).run
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

  foul transaction(work: Block<Result<Any, String>>) -> Result<Any, String> do
    …   # the owner runs `work` as one transaction (see Transactions)
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

### Transactions

`Database.transaction` runs a block as one transaction: what it does is
kept when it answers `Ok`, and undone when it answers `Error` — so a `.try`
that fails part-way undoes everything before it. Begun inside another, it
joins that one.

```kex
let made : Result<Organization, String> = Database.transaction do
  let organization = Organizations.chartered(name, slug, owner).try
  Memberships.enlisted(organization.id, owner).try
  Ok(organization)
end
```

Every statement outside a transaction is one of its own: the connection is
opened without autocommit, and `execute` and `query` commit each. Inside
one, `Direct` leaves the connection open between statements and commits or
rolls back at the end; the logger shows `BEGIN`, and `COMMIT` or
`ROLLBACK` with the time the whole transaction took.

A transaction belongs to the process running it, not to a capability: a
block uses the `Harmat.Connection` in force where it was *written*, so its
statements cannot be redirected by installing another connection around
it. A connection that asks an owning process — like `StoreConnection`
above — implements `transaction` by sending the owner the whole block, which
runs it with `Direct { connection }.transaction(work)`; inside, its own `run`
and `ask` see `Harmat.Database.ongoing()` and run on that connection
directly instead of asking the owner, which is busy with the transaction.

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
| `changeColumn(:t, from: { \|t\| … }, to: { \|t\| … })` | changing it back |
| `addIndex(:t, [:a, :b], unique: true)` | dropping the index |
| `removeIndex(:t, [:a, :b])` | creating it again |
| ``execute(sql`…`, undo: sql`…`)`` | running `undo:`; without one, nothing |

`execute` runs a literal's text as written and binds no values: write them
into the statement.

`changeColumn` takes the column as it was, `from:`, and as it becomes, `to:`.
That way it can change a column's type, its default, whether it may be
NULL, or the values it lets in:

```kex
changeColumn(:users,
  from: { |t| t.text(:role, default: "member", oneOf: ["member", "admin"]) },
  to: { |t| t.text(:role, default: "member", oneOf: ["member", "admin", "owner"]) })
```

PostgreSQL alters the column in place. SQLite can't alter a column, so
there the table is rebuilt in one transaction: it is created again with the
column changed, its rows are copied over, and its indexes are made again.
If an existing row breaks the new column's rules, the migration fails and
nothing changes.

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

- A condition is a comparison (`==`, `!=`, `<`, `<=`, `>`, `>=`), `in`,
  `isNull`, or several joined by `||` and `&&`. There is no `LIKE` and no
  joins: reach for `sql`.
- A `NULL` reads as `""`.
- No savepoints: a transaction begun inside another joins it, and undoing
  the inner one undoes both.
- Migrations are not run in a transaction: each statement commits.
- `Harmat.Query`, a builder whose chains are evaluated while the program is
  compiled, cannot be used from another package yet
  ([kexhq/kex#444](https://github.com/kexhq/kex/issues/444)). It is why the
  `sql` tag lives in `Harmat.Sql`.

## Modules

| | |
| --- | --- |
| `Harmat.Database` | the query builder: `select`, `insert`, `update`, `delete`, `within` |
| `Harmat.Confined` | what `within` gives: statements that all carry a condition |
| `Harmat.Connection` | the capability every statement is sent through; `transaction` for transactions |
| `Harmat.Logger`, `Harmat.Log` | told of every statement, timed; `Log.Console` prints them |
| `Harmat.Table`, `Harmat.Column` | declaring tables and columns; `drift` |
| `Harmat.Schema` | column handles and conditions |
| `Harmat.Migration` | migrations: the DSL, the history, `migrate` and `rollback` |
| `Harmat.Sql` | the `sql` tagged literal |
| `Harmat.Odbc` | the ODBC boundary: `connect`, `sideload`, `execute`, `query`; `executing`, `querying` and `finish` inside a transaction |
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
