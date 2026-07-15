#!/usr/bin/env bash
# Unit tests for sbx's pure naming helpers. No docker required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_TEST=1 source "$SCRIPT_DIR/../sbx"
set +e  # sbx enables -e when sourced; tests manage their own failures

fail=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc — expected '$expected', got '$actual'"
        fail=1
    fi
}

assert_eq "simple name unchanged"    "my-app"  "$(sanitize_name 'my-app')"
assert_eq "uppercase lowered"        "myapp"   "$(sanitize_name 'MyApp')"
assert_eq "space becomes dash"       "my-app"  "$(sanitize_name 'My App')"
assert_eq "unicode becomes dash"     "my-app"  "$(sanitize_name 'My✨App')"
assert_eq "inner dot kept"           "my.app"  "$(sanitize_name 'my.app')"
assert_eq "underscore kept"          "my_app"  "$(sanitize_name 'my_app')"
assert_eq "leading dot trimmed"      "hidden"  "$(sanitize_name '.hidden')"
assert_eq "junk runs squeezed"       "a-b"     "$(sanitize_name 'a--&&b')"
assert_eq "all-junk becomes empty"   ""        "$(sanitize_name '✨✨')"

h1=$(path_hash '/some/path')
h2=$(path_hash '/some/path')
h3=$(path_hash '/other/path')
assert_eq "hash deterministic" "$h1" "$h2"
if [[ "$h1" != "$h3" ]]; then echo "ok: different paths hash differently"
else echo "FAIL: same hash for different paths"; fail=1; fi
if [[ "$h1" =~ ^[0-9a-f]{4}$ ]]; then echo "ok: hash is 4 hex chars"
else echo "FAIL: hash format: '$h1'"; fail=1; fi

exit $fail
