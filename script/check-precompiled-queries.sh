#!/bin/sh
# Code-generation acceptance test, not merely a SQL-output test.
# Usage: KEX=/path/to/kex sh script/check-precompiled-queries.sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
kex=${KEX:-kex}
fixture="$repo/script/fixtures/precompiledqueries.kex"
work=$(mktemp -d "${TMPDIR:-/tmp}/harmat-precompiled.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/core"

"$kex" -E --no-colors --collapse-report --source-root "$repo/src" \
  -o "$work/core" "$fixture" > "$work/compile.log" 2>&1 || {
  cat "$work/compile.log"
  exit 1
}
core="$work/core/kex_precompiledqueries.core"

# Extract one function, rather than rejecting unused builder definitions
# emitted as runtime fallbacks elsewhere in the module.
extract() {
  awk -v header="'$1'/$2 =" '
    $0 == header { active = 1; next }
    active && /^\047[^\047]+\047\/[0-9]+ =$/ { exit }
    active { print }
  ' "$core"
}
extract query 1 > "$work/query.core"
extract dynamicQuery 2 > "$work/dynamic.core"
extract deleteQuery 1 > "$work/delete.core"

fail() { echo "precompiled queries: $*" >&2; cat "$work/query.core" >&2; exit 1; }
[ -s "$work/query.core" ] || fail 'query/1 was not emitted'
grep -F "'Harmat.Odbc.Statement'" "$work/query.core" >/dev/null || fail 'no literal statement'
grep -F '[UserId]' "$work/query.core" >/dev/null || fail 'runtime parameter was not preserved'
if grep -E '(^|[[:space:]])(call|apply|primop)[[:space:]]' "$work/query.core" >/dev/null; then
  fail 'query/1 still executes a builder or other computation'
fi

# Decode the literal binary bytes so this checks the exact SQL independently
# of temporary IR names and Core pretty-printing whitespace.
awk '
  { line = $0
    while (match(line, /#<[0-9]+>/)) {
      printf "%c", substr(line, RSTART + 2, RLENGTH - 3) + 0
      line = substr(line, RSTART + RLENGTH)
    }
  }
  END { print "" }
' "$work/query.core" > "$work/sql"
[ "$(cat "$work/sql")" = 'SELECT id, email FROM users WHERE id = ?' ] || fail 'SQL is not the expected literal'
grep -E '(call|apply).*limited' "$work/dynamic.core" >/dev/null || fail 'runtime limit did not retain its fallback'
[ -s "$work/delete.core" ] || fail 'deleteQuery/1 was not emitted'
grep -F "'Harmat.Odbc.Statement'" "$work/delete.core" >/dev/null || fail 'no literal DELETE statement'
grep -F '[UserId]' "$work/delete.core" >/dev/null || fail 'DELETE runtime parameter was not preserved'
if grep -E "call 'Kex.Harmat.Database':'(delete|where|preparedDelete|statement)'" "$work/delete.core" >/dev/null; then
  fail 'deleteQuery/1 still executes a SQL builder'
fi
awk '
  { line = $0
    while (match(line, /#<[0-9]+>/)) {
      printf "%c", substr(line, RSTART + 2, RLENGTH - 3) + 0
      line = substr(line, RSTART + RLENGTH)
    }
  }
  END { print "" }
' "$work/delete.core" > "$work/delete-sql"
grep -E 'DELETE FROM users WHERE id = \?$' "$work/delete-sql" >/dev/null || fail 'DELETE SQL is not the expected literal'

cat > "$work/expected" <<'EXPECTED'
SELECT id, email FROM users WHERE id = ?
[ada]
SELECT id, email FROM users WHERE id = ?
[bob]
SELECT id, email FROM users WHERE id = ? LIMIT 2
SELECT id, email FROM users WHERE id = ? LIMIT 7
DELETE FROM users WHERE id = ?
[ada]
EXPECTED

# Both execution engines must preserve distinct parameter values and limits.
for mode in -R -r; do
  "$kex" "$mode" --no-colors --source-root "$repo/src" "$fixture" > "$work/actual" 2>&1 || {
    cat "$work/actual"
    exit 1
  }
  diff -u "$work/expected" "$work/actual"
done

insertFixture="$repo/script/fixtures/precompiledinsert.kex"
"$kex" -E --no-colors --collapse-report --source-root "$repo/src" \
  -o "$work/core" "$insertFixture" > "$work/insert-compile.log" 2>&1 || {
  cat "$work/insert-compile.log"
  exit 1
}
core="$work/core/kex_precompiledinsert.core"
extract insertQuery 2 > "$work/insert.core"
[ -s "$work/insert.core" ] || fail 'insertQuery/2 was not emitted'
grep -F "'Harmat.Odbc.Statement'" "$work/insert.core" >/dev/null || fail 'no literal INSERT statement'
if grep -E "call 'Kex.Harmat.Database':'(insert|values|preparedInsert)'" "$work/insert.core" >/dev/null; then
  fail 'insertQuery/2 still builds INSERT SQL at runtime'
fi
extract updateQuery 2 > "$work/update.core"
[ -s "$work/update.core" ] || fail 'updateQuery/2 was not emitted'
grep -F "'Harmat.Odbc.Statement'" "$work/update.core" >/dev/null || fail 'no literal UPDATE statement'
if grep -E "call 'Kex.Harmat.Database':'(update|set|where|preparedUpdate)'" "$work/update.core" >/dev/null; then
  fail 'updateQuery/2 still builds UPDATE SQL at runtime'
fi
cat > "$work/insert-expected" <<'EXPECTED'
INSERT INTO users (id, seen_at) VALUES (?, CAST(? AS BIGINT)) [ada, 2]
INSERT INTO users (id, seen_at) VALUES (?, CAST(? AS BIGINT)) [bob, 7]
UPDATE users SET seen_at = CAST(? AS BIGINT) WHERE id = ? [3, ada]
UPDATE users SET seen_at = CAST(? AS BIGINT) WHERE id = ? [9, bob]
EXPECTED
"$kex" -r --no-colors --source-root "$repo/src" "$insertFixture" > "$work/insert-actual" 2>&1 || {
  cat "$work/insert-actual"
  exit 1
}
diff -u "$work/insert-expected" "$work/insert-actual"
printf '%s\n' 'Precompiled query acceptance passed (Core, walker, BEAM).'
