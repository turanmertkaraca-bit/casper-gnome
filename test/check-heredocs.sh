#!/bin/bash
# Guard against the bug that swallowed an entire build stage: an unterminated
# heredoc silently absorbs every following line, so the script "runs" with
# chunks of itself missing and fails somewhere unrelated, with a line number
# that shifts each time you edit. This counts opens and closes per delimiter.
set -euo pipefail
f="$1"
python3 - "$f" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read().split('\n')
# Find every heredoc opener: <<'T', <<"T", <<T, <<-T
openers = []
for i, l in enumerate(src, 1):
    for m in re.finditer(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1', l):
        openers.append((i, m.group(2)))
if not openers:
    print("no heredocs found"); sys.exit(0)

bad = 0
for line_no, tok in openers:
    # Count occurrences of the delimiter alone on a line, after the opener line
    closes = [j for j, l in enumerate(src, 1) if j > line_no and l.strip() == tok]
    if not closes:
        print("::error::heredoc opened at line %d with delimiter %r is NEVER CLOSED" % (line_no, tok))
        bad += 1
print("checked %d heredocs, %d unterminated" % (len(openers), bad))
sys.exit(1 if bad else 0)
PY
