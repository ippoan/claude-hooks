#!/bin/bash
# 全 tests/test-*.sh を順に実行し、失敗数の合計を exit code で返す aggregator。
# shell-ci.yml は test_script を 1 本しか取らないため、これを入口にして全テストを
# CI で回す。新しい hook テストを足したら tests/test-*.sh に置くだけで自動で拾う。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"
TOTAL_FAIL=0
RAN=0

for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t")"
  [ "$name" = "$SELF" ] && continue
  echo "==================== $name ===================="
  bash "$t"
  rc=$?
  RAN=$((RAN+1))
  if [ "$rc" -ne 0 ]; then
    echo ">>> $name FAILED (rc=$rc)"
    TOTAL_FAIL=$((TOTAL_FAIL + rc))
  fi
  echo ""
done

echo "==================== summary ===================="
echo "ran $RAN test file(s), total failures: $TOTAL_FAIL"
exit "$TOTAL_FAIL"
