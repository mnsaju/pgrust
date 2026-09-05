# Shared reader for a PostgreSQL Makefile's REGRESS variable.
#
# Sourced by regress/run-contrib-regress-docker.sh and
# regress/run-plpgsql-regress-docker.sh. It exists because both harnesses got
# this wrong in the same way and only one of them was taught the whole lesson:
#
#   * REGRESS is continued across backslashes (btree_gin, btree_gist, pgcrypto,
#     pg_stat_statements, test_decoding, and plpgsql's own list). A plain
#     `sed -n 's/^REGRESS *= *//p'` matches only the line that STARTS with
#     REGRESS, so every continuation is dropped. Five contrib modules ran a
#     prefix of their list and still reported PASS: 84 tests had never
#     executed. The list must be joined.
#
#   * A REGRESS entry can be an unexpanded make variable (pgcrypto's
#     $(CF_PGP_TESTS), which make resolves to pgp-compression or a DISABLED
#     placeholder depending on --with-zlib). Evaluating make is not a runner's
#     job, and passing the token through makes pg_regress try to open
#     "sql/$(CF_PGP_TESTS).sql" and abandon the whole module -- so it is
#     dropped. Dropping it SILENTLY would recreate the defect above at a
#     smaller scale, so the drop is always announced.
#
# The invariant both harnesses owe their ledgers: the test list a runner acts
# on is either the Makefile's list in full, or a shorter list it said out loud.

# regress_list_from_makefile <makefile> <label>
# Prints the space-separated test list on stdout; announces dropped tokens on
# stderr, so the caller can use this in a command substitution.
regress_list_from_makefile() {
    local mk="$1" label="$2" tests unexpanded

    tests="$(awk '
        /^REGRESS[[:space:]]*=/ { sub(/^REGRESS[[:space:]]*=[[:space:]]*/, ""); inlist = 1 }
        inlist {
            cont = /\\$/
            sub(/[[:space:]]*\\$/, "")
            printf "%s ", $0
            if (!cont) exit
        }
    ' "$mk")"

    unexpanded="$(tr ' \t' '\n\n' <<<"$tests" | grep -F '$(' || true)"
    if [ -n "$unexpanded" ]; then
        tests="$(tr ' \t' '\n\n' <<<"$tests" | grep -vF '$(' | tr '\n' ' ')"
        printf '  NOTE  %-22s skipping unexpanded make variable(s): %s\n' \
            "$label" "$(tr '\n' ' ' <<<"$unexpanded")" >&2
    fi

    printf '%s' "$tests"
}
