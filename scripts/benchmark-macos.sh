#!/bin/bash
# 1つの模擬人口と事故を共有し、生年のみ・共通仮名のみを順番に計測する。
set -euo pipefail
export LC_ALL=C

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[[ $# == 2 ]] || fail "使用方法: $0 人口 新規出力ディレクトリ"
people=$1
[[ $people =~ ^[1-9][0-9]{0,7}$ ]] && (( people >= 100 && people <= 73322000 )) ||
    fail "人口には100〜73322000の整数を指定してください"
[[ $(uname -s) == Darwin ]] || fail "この計測にはmacOSの /usr/bin/time -lp が必要です"

project_dir=$(cd "$(dirname "$0")/.." && pwd -P)
generator=${GENERATOR_BIN:-"$project_dir/target/release/seminar-synthetic-data"}
[[ -x $generator && -f $generator ]] || fail "先に cargo build --release --locked を実行するか、GENERATOR_BIN を設定してください"
"$generator" score --help >/dev/null || fail "指定した実行ファイルに score サブコマンドがありません"
duckdb=$(command -v "${DUCKDB_BIN:-duckdb}") || fail "DuckDB CLI を PATH に追加するか、DUCKDB_BIN を設定してください"
[[ -f $duckdb && -x $duckdb ]] || fail "DUCKDB_BIN に実行可能なファイルを指定してください"
DUCKDB_BIN="$(cd -- "$(dirname -- "$duckdb")" && pwd -P)/$(basename -- "$duckdb")"
export DUCKDB_BIN

# mkdirで排他的に確保し、中断した計測のログや既存のデータを上書きしない。
mkdir -p -- "$(dirname -- "$2")"
mkdir -- "$2"
output=$(cd -- "$2" && pwd -P)
population="$output/population"
round="$output/round-001"
metrics="$output/metrics.tsv"

{
    date -u '+started_utc=%Y-%m-%dT%H:%M:%SZ'
    printf 'people=%s\n' "$people"
    printf 'macOS=%s\n' "$(sw_vers -productVersion)"
    printf 'cpu=%s\n' "$(sysctl -n machdep.cpu.brand_string)"
    printf 'physical_memory_bytes=%s\n' "$(sysctl -n hw.memsize)"
    printf 'generator=%s\n' "$("$generator" --version)"
    printf 'duckdb=%s\n' "$("$DUCKDB_BIN" --version)"
    df -Pk "$output"
} > "$output/environment.txt"
printf 'stage\telapsed_seconds\tmax_rss_bytes\tparquet_bytes\tduckdb_peak_temp_bytes\n' > "$metrics"

peak_temp_bytes() {
    # DuckDB 2ではシステム指標がsystemオブジェクト配下に移動した。
    /usr/bin/plutil -extract system.peak_temp_dir_size raw "$1" 2>/dev/null ||
        /usr/bin/plutil -extract system_peak_temp_dir_size raw "$1"
}

measure() {
    local stage=$1 destination=$2
    shift 2
    local log="$output/$stage.time.log"
    printf '%s 開始\n' "$stage" >&2
    if ! /usr/bin/time -lp "$generator" "$@" --output "$destination" 2>"$log"; then
        cat "$log" >&2
        fail "$stage が失敗しました"
    fi
    local real rss parquet temp=NA
    real=$(awk '$1 == "real" {print $2}' "$log")
    rss=$(awk '/ maximum resident set size$/ {print $1}' "$log")
    [[ $real =~ ^[0-9]+([.][0-9]+)?$ && $rss =~ ^[0-9]+$ ]] || fail "$log の時間またはRSSを読み取れません"
    parquet=$(find "$destination" -type f -name '*.parquet' -exec stat -f '%z' {} + |
        awk '{sum += $1} END {printf "%.0f", sum}')
    if [[ $stage == score-* ]]; then
        local match_temp score_temp
        match_temp=$(peak_temp_bytes "$destination/match-profile.json")
        score_temp=$(peak_temp_bytes "$destination/score-profile.json")
        [[ $match_temp =~ ^[0-9]+$ && $score_temp =~ ^[0-9]+$ ]] || fail "DuckDBの一時領域の最大値が不正です"
        temp=$((match_temp > score_temp ? match_temp : score_temp))
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$stage" "$real" "$rss" "$parquet" "$temp" | tee -a "$metrics"
}

measure population "$population" population --people "$people" --seed 2026 --chunk-size 100000
measure incidents "$round" incidents --population "$population" --seed 1701 \
    --service-size "$((people / 4))" --overlap-percent 50 --mail-reuse-percent 50 \
    --past-incidents 3 --past-size "$((people * 6 / 100))" --new-size "$((people / 100))" \
    --known-identity-percent 100 --health-recorded-percent 100 --name-mode shared --past-mask 5 --new-mask 5
measure score-birth-year "$output/score-birth-year" score --incidents "$round" --mask 4 --birth-year
measure score-shared-name "$output/score-shared-name" score --incidents "$round" --mask 1
