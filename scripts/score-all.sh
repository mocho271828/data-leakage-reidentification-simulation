#!/bin/bash
# 同一の事故履歴・対象者を使って、5項目の有無の全組合せを比較する。
set -euo pipefail

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[[ $# == 2 ]] || fail "使用方法: $0 事故ディレクトリ 新規出力ディレクトリ"
incidents=$(cd -- "$1" && pwd -P)
project=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
generator=$(command -v "${GENERATOR_BIN:-$project/target/release/seminar-synthetic-data}") ||
    fail "cargo build --release --locked を実行するか、GENERATOR_BIN を設定してください"
duckdb=$(command -v "${DUCKDB_BIN:-duckdb}") ||
    fail "DuckDB CLI を PATH に追加するか、DUCKDB_BIN を設定してください"
DUCKDB_BIN="$(cd -- "$(dirname -- "$duckdb")" && pwd -P)/$(basename -- "$duckdb")"
export DUCKDB_BIN

# 出力先は排他的に確保し、中断時は完了済みの条件別データを残す。
mkdir -p -- "$(dirname -- "$2")"
mkdir -- "$2"
output=$(cd -- "$2" && pwd -P)
summaries=()
for (( mask=0; mask<32; mask++ )); do
    printf -v subdir '%02d' "$mask"
    "$generator" score --incidents "$incidents" --mask "$mask" --output "$output/$subdir"
    summaries+=("$output/$subdir/summary.csv")
done

# 個別CSVはサービス名と数値・真偽値だけを含む。ヘッダーとA/Bの両行を確認して公開する。
awk -F, '
    FNR == 1 {
        if (NR == 1) {
            header = $0
            print "mask," header
        }
        if ($0 != header || $1 != "service") exit 1
        next
    }
    {
        count = split(FILENAME, parts, "/")
        mask = parts[count - 1] + 0
        if (($1 != "A" && $1 != "B") || seen[mask, $1]++) exit 1
        print mask "," $0
    }
    END {
        for (i = 0; i < 32; i++)
            if (!seen[i, "A"] || !seen[i, "B"]) exit 1
    }
' "${summaries[@]}" > "$output/.summary.csv" || fail "32条件分の summary.csv を統合できませんでした"
mv -- "$output/.summary.csv" "$output/summary.csv"
printf '%s\n' "$output/summary.csv"
