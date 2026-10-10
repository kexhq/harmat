#!/bin/sh
# Builds Erlang's ODBC port program (odbcserver) for an OTP install that was
# packaged without it, into a directory `Harmat.Database.sideload` can load.
#
# Kex 0.4 needs OTP 29+, and Homebrew's erlang bottle ships lib/odbc with its
# .beam files but no priv/bin/odbcserver, so odbc:connect/2 dies with
# port_program_executable_not_found. Nothing is written outside the output
# directory: the result is <dir>/odbc-<vsn>/{ebin,priv/bin/odbcserver}.
#
#   script/setup-odbc.sh                 # into ./.odbc, newest erl on PATH
#   script/setup-odbc.sh db/odbc         # into another directory
#   script/setup-odbc.sh db/odbc /path/erl
#
# Needs: a C compiler, curl, unixODBC headers (brew install unixodbc).
set -eu

release_of() {
  "$1" -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo 0
}

out="${1:-.odbc}"
erl="${2:-}"
if [ -z "$erl" ]; then
  best=0
  for candidate in $(which -a erl 2>/dev/null); do
    release=$(release_of "$candidate")
    if [ "$release" -gt "$best" ]; then best=$release; erl=$candidate; fi
  done
fi
[ -n "$erl" ] || { echo "setup-odbc: no erl found on PATH" >&2; exit 1; }

info() { "$erl" -noshell -eval "io:format(\"~s\", [$1]), halt()."; }

root=$(info 'code:root_dir()')
odbc_lib=$(info 'code:lib_dir(odbc)')
ei_lib=$(info 'code:lib_dir(erl_interface)')
odbc_app=$(basename "$odbc_lib")
otp_version=$(cat "$root/releases/$(release_of "$erl")/OTP_VERSION")

if [ -x "$odbc_lib/priv/bin/odbcserver" ]; then
  echo "setup-odbc: $erl (OTP $otp_version) already ships odbcserver; nothing to do."
  exit 0
fi

prefix=$(brew --prefix unixodbc 2>/dev/null || echo /usr)
[ -f "$prefix/include/sql.h" ] || { echo "setup-odbc: unixODBC headers not found (brew install unixodbc)" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "setup-odbc: building odbcserver for OTP $otp_version ($erl)"
for file in odbcserver.c odbcserver.h; do
  curl -fsSL -o "$work/$file" "https://raw.githubusercontent.com/erlang/otp/OTP-$otp_version/lib/odbc/c_src/$file"
done

target="$out/$odbc_app"
rm -rf "$target"
mkdir -p "$target/priv/bin"
cp -R "$odbc_lib/ebin" "$target/ebin"
cc -O2 -w -DUNIX -DHAVE_STRUCT_SOCKADDR_IN6_SIN6_ADDR \
  -I"$ei_lib/include" -I"$prefix/include" \
  -o "$target/priv/bin/odbcserver" "$work/odbcserver.c" \
  -L"$ei_lib/lib" -lei -L"$prefix/lib" -lodbc -lpthread

echo "setup-odbc: wrote $target/priv/bin/odbcserver"
