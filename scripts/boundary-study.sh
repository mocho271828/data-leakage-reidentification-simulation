#!/bin/bash
# 全国名簿シード2026の実測人数を使う。confirmは出力先のexplore-summary.csvを読む。
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 first|explore|confirm OUTPUT_DIRECTORY" >&2; exit 1; }
phase=$1
seed=51000
repetitions=30
case "$phase" in
    first) percents='[24]'; counts='[5, 6, 7]'; sizes='[1]' ;;
    explore) percents='[12, 24]'; counts='range(1, 57)'; sizes='[1, 10, 100]' ;;
    confirm) seed=91000; repetitions=400 ;;
    *) echo "unknown phase: $phase" >&2; exit 1 ;;
esac
project=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
duckdb=$(command -v "${DUCKDB_BIN:-duckdb}") || { echo "DuckDB CLI が見つかりません" >&2; exit 1; }
duckdb=$(cd -- "$(dirname -- "$duckdb")" && pwd -P)/$(basename -- "$duckdb")
mkdir -p -- "$2"
output=$(cd -- "$2" && pwd -P)
files=("$phase-grid.csv" "$phase-trials.csv" "$phase-summary.csv")
if [[ $phase == confirm ]]; then
    [[ -f "$output/explore-summary.csv" ]] || { echo "先に explore を実行してください" >&2; exit 1; }
    files+=(boundary-theory.csv)
fi
for file in "${files[@]}"; do
    [[ ! -e "$output/$file" && ! -L "$output/$file" ]] || { echo "出力先は既存です: $output/$file" >&2; exit 1; }
done

work=$(mktemp -d "$output/.$phase.XXXXXXXX")
cleanup() {
    local status=$?
    if (( status != 0 )); then
        # 公開途中で失敗した場合も、他の実行が作ったファイルは保持する。
        for file in "${files[@]}"; do
            if [[ "$work/$file" -ef "$output/$file" ]]; then rm -- "$output/$file"; fi
        done
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cd -- "$work"
if [[ $phase == confirm ]]; then
    ln -s "$output/explore-summary.csv" explore-summary.csv
    cp "$project/docs/boundary-theory.csv" boundary-theory.csv
    "$duckdb" -bail -csv < "$project/scripts/boundary-confirm-grid.sql" > confirm-grid.csv
else
    "$duckdb" -bail -csv > "$phase-grid.csv" <<SQL
SELECT past_percent, past_count, new_size, mask
FROM unnest($percents) AS percentages(past_percent)
CROSS JOIN unnest($counts) AS counts(past_count)
CROSS JOIN unnest($sizes) AS sizes(new_size)
CROSS JOIN unnest([2, 3, 31]) AS masks(mask)
ORDER BY past_percent, past_count, new_size, mask;
SQL
fi
"$project/target/release/examples/boundary_study" --population 73322000 --service-size 18330500 \
    --overlap-count 9165250 --reuse-count 4582625 --license-holders 61112249 \
    --first-seed "$seed" --repetitions "$repetitions" --grid "$phase-grid.csv" --output "$phase-trials.csv"
"$duckdb" -bail -csv -cmd "SET VARIABLE trials_csv='$phase-trials.csv'" \
    < "$project/scripts/boundary-summary.sql" > "$phase-summary.csv"

# 同一ボリューム内のハードリンクなら、並行実行が先に作った同名ファイルも置き換えない。
for file in "${files[@]}"; do
    ln "$work/$file" "$output/"
done
