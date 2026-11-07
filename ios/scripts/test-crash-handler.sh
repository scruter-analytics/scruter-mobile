#!/bin/bash
# Real crashes under ScruterCrash's handlers (macOS: the same Mach and POSIX code as iOS): each mode must write a
# complete report, with the crashed thread's frames, the main thread, the binary images and the context; a handler
# installed before the SDK's still runs.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun clang -O0 -g -fno-omit-frame-pointer -I "$root/ios/Sources/ScruterCrash/include" \
  "$root/ios/scripts/crash_probe.c" "$root/ios/Sources/ScruterCrash/crash.c" -o "$work/probe" || exit 1

check() { # mode mach expected-type expected-sig expected-threads
  local mode=$1 mach=$2 type=$3 sig=$4 threads=$5 report="$work/$1-$2.report"
  "$work/probe" "$report" "$mode" "$mach" 3>"$work/marker" 2>/dev/null
  local status=$?
  [ "$status" -ge 128 ] || { echo "$mode mach=$mach: the process did not die of a signal (exit $status)"; exit 1; }
  head -1 "$report" | grep -q '^SCRUTER-CRASH 1$' || { echo "$mode mach=$mach: no report"; exit 1; }
  for want in "^kind crash$" "^type $type$" "^sig $sig$" '^ctx {"s":"0123456789abcdef"' '^end$' '^img 0x.* probe$'; do
    grep -Eq "$want" "$report" || { echo "$mode mach=$mach: '$want' missing"; cat "$report" | head -20; exit 1; }
  done
  [ "$(grep -c '^thread ' "$report")" = "$threads" ] || { echo "$mode mach=$mach: threads"; grep -n '^thread' "$report"; exit 1; }
  [ "$(grep -c '^f 0x' "$report")" -ge 2 ] || { echo "$mode mach=$mach: frames"; exit 1; }
  echo "$mode mach=$mach: $(grep -c '^f 0x' "$report") frames, $(grep -c '^img ' "$report") images"
}

check segv 0 EXC_BAD_ACCESS 'SIG(SEGV|BUS)' 1
check segv 1 EXC_BAD_ACCESS 'SIG(SEGV|BUS)' 1
check abort 0 EXC_CRASH SIGABRT 1
check abort 1 EXC_CRASH SIGABRT 1
check trap 0 '(EXC_BREAKPOINT|EXC_BAD_INSTRUCTION)' 'SIG(TRAP|ILL)' 1
check trap 1 '(EXC_BREAKPOINT|EXC_BAD_INSTRUCTION)' 'SIG(TRAP|ILL)' 1
check thread 0 EXC_BAD_ACCESS 'SIG(SEGV|BUS)' 2
check thread 1 EXC_BAD_ACCESS 'SIG(SEGV|BUS)' 2
check overflow 1 EXC_BAD_ACCESS 'SIG(SEGV|BUS)' 2
check chained 0 EXC_BAD_ACCESS 'SIG(SEGV|BUS)' 1
grep -q chained "$work/marker" || { echo "the previous handler did not run"; exit 1; }
# After a JavaScript or Dart fatal error: the process dies as usual, without a second report.
"$work/probe" "$work/muted.report" muted 0 3>"$work/marker" 2>/dev/null
[ "$?" -ge 128 ] || { echo "muted: the process did not die of a signal"; exit 1; }
[ ! -s "$work/muted.report" ] || { echo "muted: a report was written"; exit 1; }
echo "crash handlers: reports complete, previous handlers chained"
