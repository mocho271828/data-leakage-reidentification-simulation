# 情報漏えいと再識別の模擬実験

講義で配布された資料を参考に、過去の漏えい記録と保存項目の組み合わせが本人の特定にどう影響するかを、架空のデータを使って調べます。

[実験計画](docs/実験計画.md) · [予備実験の結果](docs/ローカル予備実験.md) · [全員正答確率の反復実験](docs/全員正答確率の反復実験.md) · [過去の本人対応率を変えた実験](docs/本人対応率を変えた反復実験.md) · [公表事例をもとにした追加実験](docs/漏えい対象と項目の偏り.md)

## 条件を指定して反復する

RubyとDuckDB CLIを使います。DuckDBを `PATH` に追加するか、`DUCKDB_BIN` に実行ファイルを指定してください。次の例では架空人口を一度生成し、事故シード120000～120029で30回実験します。既存の人口表を使う場合は `--population` にそのディレクトリを指定します。

```sh
cargo build --release --locked
target/release/seminar-synthetic-data population --people 1000 --seed 2026 --output output/example-population
scripts/repeat-experiment.rb --population output/example-population --output output/example-trials \
  --first-seed 120000 --repetitions 30 --service-size 200 \
  --past-incidents 2 --past-size 100 --new-size 10 --masks 0,2,3,31 --max-bytes 67108864
```

`--output` には既存の親ディレクトリの下に新しい名前を指定します。各反復で登録者・過去事故・新規対象者を引き直し、指定した照合マスクすべてに同じ事故を使います。マスクは氏名1・メール2・生年月日4・世帯住所8・免許証番号16の和です。省略すると過去・新規の両方にある列から全組み合わせを試します（標準設定は32通り）。過去の本人対応率はこのスクリプトでは100%で、`--known-identity-percent` で変更できます。その他の条件は `--help` で確認できます。探索と確認を分けるときは、両者で重ならないシード範囲を指定してください。

出力先の `summary.csv` はサービスA・Bとマスクごとに1行です。`successes / trials` が全員正答した反復の割合 `rate` です。両側95% Wilson信頼区間（`lower95`, `upper95`）の下限が80%以上なら `reached`、上限が80%未満なら `below`、その間は `uncertain` とします。人単位の正答・誤特定・保留の各率、健診結果が判明した平均人数、全員が過去にも登場した反復の割合も併記します。

実験条件と人口シードは `conditions.json` と `population-manifest.json`、各回の事故シード・生成条件と採点結果は `trial-番号/incident-manifest.json` と `trial-番号/summary.csv` に残ります。既定では各回の全マスクについてA・Bの人数と全員正答フラグを検証し、その回のCSVを保存してから事故表・行別予測・プロファイルを整理します。`--keep-details` を付けるとこれらも保存します。

`--max-bytes` は実行先内の通常ファイルの論理サイズの合計に適用します。入力人口は含まず、実行先内の一時ファイルは含みます。集計の書き込み前と生成・採点コマンドの実行中および終了時に確認します。超過を検知すると停止しますが、監視間隔中に書かれた未検証のファイルを保持するため、停止後も指定容量を超えている場合があります。中断時は完了した反復を利用でき、実行全体の `summary.csv` は作成されません。
