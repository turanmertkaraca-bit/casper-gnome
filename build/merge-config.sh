#!/usr/bin/env bash
# Merge a kernel config fragment into an existing .config on stdout.
#
# Kernel config merging looks trivial and is not. Three things this handles
# that a naive `cat fragment >> .config` does not:
#
#  1. A symbol may already exist as `CONFIG_X=old` or as `# CONFIG_X is not set`.
#     Appending leaves BOTH lines in place. Kconfig takes the last one, so it
#     usually "works" — and then the file lies to every human who reads it, and
#     tools that parse configs get two answers. Always replace.
#
#  2. `# CONFIG_X is not set` is a real, meaningful value (it forces a bool off
#     and prevents Kconfig from defaulting it on). A fragment that says
#     "CONFIG_X is not set" must strip an existing CONFIG_X=y, or the two fight
#     and the outcome depends on line order.
#
#  3. Duplicate symbols inside the fragment itself must collapse to the last
#     occurrence, matching Kconfig's own semantics.
#
# Usage: merge-config.sh <in.config> <fragment> > merged.config
set -euo pipefail

CONFIG="${1:?usage: merge-config.sh <config> <fragment>}"
FRAG="${2:?usage: merge-config.sh <config> <fragment>}"
[ -f "$CONFIG" ] || { echo "no such config: $CONFIG" >&2; exit 2; }
[ -f "$FRAG" ]   || { echo "no such fragment: $FRAG" >&2; exit 2; }

# Normalise the fragment: strip comments/blank lines, collapse duplicates so
# that the LAST assignment wins (same as Kconfig), emit "SYM<TAB>VALUE".
# Value is the full right-hand side, including the `is not set` form.
parse() {
    awk '
        /^[[:space:]]*#/ { next }              # comment
        /^[[:space:]]*$/ { next }              # blank
        /^CONFIG_[A-Za-z0-9_]+=/ {
            sym = $0; sub(/=.*/, "", sym); sub(/^CONFIG_/, "", sym)
            val = $0; sub(/^[^=]*=/, "", val)
            last[sym] = val
            order[++n] = sym
            next
        }
        /^# CONFIG_[A-Za-z0-9_]+ is not set/ {
            sym = $0
            sub(/^# CONFIG_/, "", sym); sub(/ is not set.*/, "", sym)
            last[sym] = "n"
            order[++n] = sym
            next
        }
        { next }
        END {
            # emit in first-appearance order, but only the final value
            seen_done = ""
            for (i = 1; i <= n; i++) {
                s = order[i]
                if (s in emitted) continue
                emitted[s] = 1
                v = last[s]
                if (v == "n") print s "\tn"
                else          print s "\t" v
            }
        }
    ' "$1"
}

# Classes where a later sym with the same prefix must displace an earlier one.
# Kconfig semantics: e.g. setting CONFIG_ZRAM_DEF_COMP_LZ4=y implies
# CONFIG_ZRAM_DEF_COMP_ZSTD is no longer set, because they are a choice group.
# Without this, a fragment that changes a choice leaves the old member =y and
# the kernel build fails on "multiple choice selections".
is_choice_group() { case "$1" in
    ZRAM_DEF_COMP|DEFAULT_SECURITY|IOSCHED|CPU_FREQ_DEFAULT_GOV|ZSWAP_COMPRESSOR|\
    DEFAULT_IO_SCHEDULER|CC_HAS_*) return 0 ;;
    *) return 1 ;;
esac; }

parse "$FRAG" > /tmp/.fragmap.$$ || { rm -f /tmp/.fragmap.$$; exit 1; }
trap 'rm -f /tmp/.fragmap.$$' EXIT

# Build the set of symbols the fragment speaks about.
cut -f1 /tmp/.fragmap.$$ | sort -u > /tmp/.fragsyms.$$

parse "$CONFIG" > /tmp/.cfgmap.$$

# Pass 1: original config, emitting whatever the fragment does not override.
awk -F'\t' -v OFS='\t' '
    NR==FNR { override[$1]=1; next }
    {
        s=$1
        if (s in override) next          # fragment wins; skip the old line
        print s, $2
    }
' /tmp/.fragsyms.$$ /tmp/.cfgmap.$$ > /tmp/.basekeep.$$

# Pass 2: append the fragment's values, then normalise choice-group conflicts.
cat /tmp/.basekeep.$$ /tmp/.fragmap.$$ | awk -F'\t' -v OFS='\t' '
    { val[$1]=$2; if (!($1 in seen)) { seen[$1]=1; ord[++n]=$1 } }
    END {
        # collapse choice groups: if several members of one group are =y, keep
        # only the last-mentioned one, and mark the rest "n".
        split("ZRAM_DEF_COMP DEFAULT_SECURITY IOSCHED CPU_FREQ_DEFAULT_GOV ZSWAP_COMPRESSOR DEFAULT_IO_SCHEDULER", groups, " ")
        for (g in groups) {
            base = groups[g]
            lastwinner = ""
            for (i = 1; i <= n; i++) {
                s = ord[i]
                if (index(s, base) == 1 && val[s] == "y") lastwinner = s
            }
            if (lastwinner != "") {
                for (i = 1; i <= n; i++) {
                    s = ord[i]
                    if (index(s, base) == 1 && val[s] == "y" && s != lastwinner) val[s] = "n"
                }
            }
        }
        for (i = 1; i <= n; i++) {
            s = ord[i]; v = val[s]
            if (v == "n")      print "# CONFIG_" s " is not set"
            else               print "CONFIG_" s "=" v
        }
    }
' > /tmp/.final.$$

cat /tmp/.final.$$
rm -f /tmp/.fragmap.$$ /tmp/.fragsyms.$$ /tmp/.cfgmap.$$ /tmp/.basekeep.$$ /tmp/.final.$$
