#!/usr/bin/env bash
# std.unicode.Utf8Iterator and Utf8View.initUnchecked assume valid UTF-8 and
# hit `catch unreachable` on a malformed byte. In release builds that is
# undefined behavior: Reader mode spun forever on a box-drawing rule split
# mid-codepoint. Text shown in the UI comes from documents and terminal output,
# so iterate it with src/ui/utf8_text.zig or validate it with Utf8View.init.
set -euo pipefail

cd "$(dirname "$0")/.."

if matches=$(grep -rnE 'Utf8Iterator[[:space:]]*\{|Utf8View\.initUnchecked' src --include='*.zig'); then
    echo "error: unchecked UTF-8 iteration; use src/ui/utf8_text.zig or Utf8View.init:" >&2
    echo "$matches" >&2
    exit 1
fi

echo "unchecked UTF-8: none found"
