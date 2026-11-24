# 模擬人口と漏えいデータの生成

[実験計画](実験計画.md)の基本32条件で共用する人口表と, サービスA・Bの登録・漏えいデータを生成するRustプログラムです. 1万人の生成例は [output/pilot](output/pilot/) にあります. 氏名, 住所, メール, 免許証番号はすべて架空の整数コードです.

## 1万人で一度実行する

このREADMEと同じディレクトリで以下を実行します. 検証に使用した環境はRustとCargoの1.99.1です. 各コマンドの `--output` には新しいディレクトリを指定します.

```sh
cargo build --locked
generator=./target/debug/seminar-synthetic-data

"$generator" population --people 10000 --seed 2026 --chunk-size 4000 \
  --output output/demo/population

"$generator" incidents --population output/demo/population --seed 1701 \
  --service-size 2500 --overlap-percent 50 --mail-reuse-percent 50 \
  --past-incidents 3 --past-size 600 --new-size 100 --known-identity-percent 100 \
  --output output/demo/round-001

"$generator" project --incidents output/demo/round-001 --mask 3 \
  --output output/demo/name-mail
```

この例ではA・Bに各2,500人が登録し, 共通登録者1,250人のうち625人が両方で同じメールを使います. Aの過去3事故は延べ1,800行, 実人数1,400人です. 新規事故はA・B各100行で, 過去に一度も登場しなかった人はAで41人, Bで75人です. どの保存条件にもこの人たちを含めます.

## 32条件の作り方

`--mask` には保存する項目の値を足した数を指定します.

| 項目 | 値 | 基本条件の列 |
|---|---:|---|
| 氏名 | 1 | `surname_code`, `given_name_code` |
| メール | 2 | `mail_code` |
| 生年月日 | 4 | `birth_date`（1970-01-01からの日数） |
| 世帯住所 | 8 | `household_code` |
| 免許証番号 | 16 | `license_code`（非保有はNULL） |

たとえば `3` は氏名とメール, `10` はメールと住所です. `0` でも事故内の行番号 `row_id` と新規の健診判定 `health_code` は残ります. `row_id` はファイルごとに振り直すため, ある事故の行と別の事故の同じ行番号は別々に扱います.

```sh
for mask in $(seq 0 31); do
  "$generator" project --incidents output/demo/round-001 --mask "$mask" \
    --output "output/demo/conditions/mask-$mask" || break
done
```

`project` は, 指定した列を新規A・Bの表から元の行順で取り出します. 32条件を比べる場合は, `incidents` の `--new-mask` を既定値の `31` にします. 過去側に含める列は `--past-mask` で別に指定できます. 人口を固定して別の反復を作るには, 同じ `--population` を指定し, `incidents` の `--seed` と出力先を変えます. 同じ設定・シードで `--past-incidents` を増やすと, 以前の過去事故を保ったまま新しい履歴が加わります.

## 出力の読み方

| 出力先 | 用途 |
|---|---|
| 人口の `scoring/population/part-*.parquet` | 1人1行の原表. 人物ID, 人口区分, 生年月日, 姓・名, 世帯・町域・市区町村・都道府県, 免許証番号を収録 |
| 人口の `manifest.json` | 人口シード, 出典・基準日, 年齢別人数と免許保有者数, 世帯人数分布, 姓の人数分布 |
| 反復の `matching/` | 照合に使う過去Aの事故別Parquetと新規A・BのParquet. 新規にだけ健診判定を収録 |
| 反復の `identity/past-A-*.parquet` | 本人が既知の過去行について, 事故内の行番号と架空の名簿番号を対応づける. 既知率が正のときに生成 |
| 反復の `scoring/` | 正解の人物IDとの対応表, 新規対象者全員の健診判定の正解, A・Bの登録表. `manifest.json` に事故件数, 延べ人数・実人数, 重複・欠損の集計と生成条件を記録 |
| 各条件の `matching/`, `manifest.json` | 指定した項目だけの新規A・Bの表と, 共用する過去・採点データへの参照. 参照元の反復ディレクトリと一緒に保管する |

模擬照合には `matching/` と, 条件で照合者に与える `identity/` を使います. `scoring/` は結果を採点するときに使います. 二つのテーブルを事故内で対応づけるキーは, 同じファイル名と `row_id` の組です.

## 統計に合わせた分布と実験上の仮定

- **人口・年齢**　2026年5月1日の国内15～64歳を対象に, 全国規模で73,322,000人, うち日本人相当69,873,000人に合わせます. 小規模ではこの構成に比例配分し, 各5歳階級内で生年月日を一様に選びます. [総務省統計局「人口推計 2026年10月報」](https://www.stat.go.jp/data/jinsui/pdf/202610.pdf)
- **世帯・住所**　一般世帯の世帯人員分布を基に, 各世帯員が15～64歳である確率を独立に59.5%と仮定します. 対象年齢の同居人には同じ住所を割り当てます. 家族関係や実在地域の人口密度はモデル化していません. [総務省統計局「令和2年国勢調査 人口等基本集計」](https://www.stat.go.jp/data/kokusei/2020/kekka/pdf/outline_01.pdf)
- **姓・名**　上位100姓は保険契約者の調査を近似として用い, 上位10姓・100姓の合計も公表割合に合わせます. 101位以下は `--tail many-rare`（少人数の姓を多くする）と `even`（均等）を選べます. 名の世代別分布と世帯内の姓の共有は実験上の仮定です. [明治安田生命「全国同姓調査」](https://www.meijiyasuda.co.jp/profile/news/release/2018/pdf/20180808_01.pdf)
- **運転免許**　2025年末の保有者数と2026年1月1日の人口から年齢別の保有確率を求めます. 15歳は非保有とし, 保有者だけに重複しない架空番号を割り当てます. [警察庁「運転免許統計 令和7年版」](https://www.npa.go.jp/publications/statistics/koutsuu/r07main.pdf)・[総務省統計局「人口推計 2026年6月報」](https://www.stat.go.jp/data/jinsui/pdf/202606.pdf)
- **サービスと健診**　各事故の対象者は登録者から重複なく無作為抽出します. `--name-mode full|shared|service` で, 模擬氏名・両サービス共通の仮名・サービス別仮名を選びます. 健診判定は人物ごとに3区分から等確率で選び, `--health-recorded-percent` で値が観測される確率を指定します（既定100%）. 空欄でもその人の行は残ります. `--known-identity-percent` は過去の各行を本人と対応づけられる確率です（既定0%, 上記の生成例は100%）.

今回の基本条件では登録後の転居・改姓・メール変更と, 登録項目の個別欠損は0件です. 年齢や地域に偏った登録, 相談窓口の利用者に限定する抽出, 生年月日・住所の粒度の比較は計画上の追加条件です.

## 計画書の手計算例を再現する

同居する2人を過去Aの本人既知記録に含めた小さな例です. 下記では新規事故の人数だけを変えます.

```sh
"$generator" population --people 3 --seed 1 --output output/hand/population
for n in 1 2; do
  "$generator" incidents --population output/hand/population --seed 5 \
    --service-size 3 --overlap-percent 100 --mail-reuse-percent 100 \
    --past-incidents 1 --past-size 2 --past-mask 10 --new-mask 10 \
    --known-identity-percent 100 --new-size "$n" --output "output/hand/new-$n"
done
```

`matching/past-A-00001.parquet` の2人は同じ世帯で, メールコードは4と3です. 新規Aが1人のとき, メールコード4の人は住所だけなら候補2人, 住所とメールなら候補1人です. 新規Aを2人にすると, メールコード2の過去未登場者が加わります. 住所とメールを使った場合の手計算結果は正答1人・保留1人です.

## 人口規模を変える

全国規模の人口表を生成するコマンドです. `--people` を `1000000` や `10000000` に変えると, 同じ手順で予備実験ができます. `--chunk-size` は1ファイルの最大人数で, 人口シードが同じなら分割単位を変えても人物の値と順序は再現されます.

```sh
cargo run --release --locked -- population --people 73322000 --seed 2026 \
  --chunk-size 100000 --output output/national/population
```

## 照合と採点を再現する

`score` は事故データを照合し、新規A・Bの各行について候補人数と回答を `predictions.parquet` に保存します。過去の本人既知記録を事故横断で集計し、指定した項目がすべて一致する名簿上の人物を数えます。同じ人が複数の事故に登場しても候補は1人です。選んだ項目に欠損がある行、照合項目がない条件、候補が0人または複数の行は保留になります。過去・新規とも選択した列を持つ反復を指定します。

実行には DuckDB CLI を使います。検証に使ったバージョンは 2.0.1 です。`duckdb` を PATH に置くか、実行ファイルのパスを環境変数 `DUCKDB_BIN` に設定します。[DuckDB CLI 配布元](https://github.com/duckdb/duckdb/releases/tag/v2.0.1)

```sh
cargo build --release --locked
./target/release/seminar-synthetic-data score \
  --incidents output/hand/new-2 --mask 10 --output output/hand/address-mail
scripts/score-all.sh output/pilot/round-001 output/pilot-scores
```

最初の例は上の3人の手計算例を使います。候補が1人ならその名簿番号を回答し、予測を保存した後に採点用の本人IDと突き合わせます。`summary.csv` の `correct`、`incorrect`、`unresolved` は順に正答・誤特定・保留の人数で、合計は各サービスの `targets` に一致します。`all_correct` は新規の対象者全員が正答したときだけ真になります。`health_revealed` は正しい本人と、実際に記録された正しい健診結果を結び付けた人数です。

2番目の例では、同じ反復から必要な列だけを読み、32条件の結果を1枚の `summary.csv`（32条件 × 2サービス）にまとめます。各条件の予測とDuckDBの照合・採点プロファイルも残ります。Macで規模ごとの計測を再現するには、各行に新規の出力先を指定します。

```sh
scripts/benchmark-macos.sh 1000000 output/bench/1m
scripts/benchmark-macos.sh 10000000 output/bench/10m
scripts/benchmark-macos.sh 73322000 output/bench/national
```

各規模で、事故履歴を1回生成し、生年だけを使う条件（`--mask 4 --birth-year`）と、全サービス共通の一意な仮名だけを使う条件（`--mask 1`）を順に採点します。工程別の時間・メモリ・Parquet容量・DuckDBの一時ディスク使用量は `metrics.tsv`、実行環境は `environment.txt` に保存します。[ローカル予備実験の結果](ローカル予備実験.md)
