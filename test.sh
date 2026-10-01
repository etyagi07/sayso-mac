#!/usr/bin/env bash
# Every test in this repo, in one go: the engine fork, the bridge, the panel.
# Nothing is sent anywhere and no test touches live state (each suite runs in a
# throwaway SAYSO_HOME). Exits non-zero if anything fails.
#   ./test.sh
set -uo pipefail
cd "$(dirname "$0")"
failed=0

echo "── engine (sayso/tests)"
for t in sayso/tests/test_*.py; do
  if out=$(cd sayso && .venv/bin/python "${t#sayso/}" 2>&1) && echo "$out" | grep -q ' 0 failed'; then
    echo "  ok   $(basename "$t") ($(echo "$out" | tail -1))"
  else
    echo "  FAIL $(basename "$t")"; echo "$out" | grep -E 'FAIL|Error' | head -5 | sed 's/^/       /'
    failed=1
  fi
done

echo "── bridge (tests/)"
if out=$(sayso/.venv/bin/python -m unittest discover -s tests 2>&1) && echo "$out" | grep -q '^OK'; then
  echo "  ok   $(echo "$out" | grep '^Ran')"
else
  echo "$out" | grep -E '^(FAIL|ERROR)|^Ran|FAILED' | sed 's/^/  /'; failed=1
fi

echo "── panel (app/Tests)"
if out=$(cd app && swift test 2>&1) && echo "$out" | grep -q 'with 0 failures'; then
  echo "  ok   $(echo "$out" | grep -o 'Executed [0-9]* tests' | tail -1)"
else
  echo "$out" | grep -E 'error:|Executed' | tail -5 | sed 's/^/  /'; failed=1
fi

[ $failed -eq 0 ] && echo "all passed" || echo "SOMETHING FAILED"
exit $failed
