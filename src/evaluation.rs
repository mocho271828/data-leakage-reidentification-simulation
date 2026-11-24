use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, ensure};
use clap::Args;
use polars::prelude::{ParquetReader, SerReader};

use crate::projection::key_columns;

#[derive(Args)]
pub struct ScoreArgs {
    /// incidents で生成した1反復分のディレクトリ
    #[arg(long)]
    incidents: PathBuf,
    /// 照合に使う列。1=氏名、2=メール、4=生年月日、8=世帯住所、16=免許の和
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=31))]
    mask: u8,
    /// 生年月日を選ぶ条件で、過去・新規の双方を生年に丸める
    #[arg(long)]
    birth_year: bool,
}

fn history_files(dir: &Path) -> Result<BTreeSet<OsString>> {
    let mut files = BTreeSet::new();
    for entry in fs::read_dir(dir).with_context(|| format!("{} を開けません", dir.display()))?
    {
        let name = entry?.file_name();
        if let Some(value) = name.to_str()
            && value.starts_with("past-A-")
            && value.ends_with(".parquet")
        {
            files.insert(name);
        }
    }
    Ok(files)
}

fn sql_path(path: &Path) -> Result<String> {
    let name = path
        .to_str()
        .context("DuckDB のパスには UTF-8 が必要です")?;
    Ok(format!("'{}'", name.replace('\'', "''")))
}

fn profile_copy(
    executable: &Path,
    source: &Path,
    staging: &Path,
    profile_name: &str,
    query: &str,
) -> Result<()> {
    let profile = sql_path(&staging.join(profile_name))?;
    let spill = sql_path(&staging.join("duckdb-tmp"))?;
    let sql = format!(
        "SET temp_directory={spill};
         SET profiling_coverage='ALL';
         SET enable_profiling='json';
         SET profiling_output={profile};
         {query}"
    );
    let output = Command::new(executable)
        .current_dir(source)
        .args(["-batch", "-bail", ":memory:", "-c", &sql])
        .output()
        .with_context(|| format!("DuckDB を起動できません: {}", executable.display()))?;
    ensure!(
        output.status.success(),
        "DuckDB の処理に失敗しました ({profile_name}): {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    ensure!(
        staging.join(profile_name).is_file(),
        "DuckDB が {profile_name} を生成しませんでした"
    );
    Ok(())
}

fn predict_sql(keys: &[&str], birth_year: bool, has_known_history: bool) -> String {
    let columns = keys
        .iter()
        .map(|&name| {
            if birth_year && name == "birth_date" {
                "year(DATE '1970-01-01' + birth_date) AS birth_date"
            } else {
                name
            }
        })
        .collect::<Vec<_>>()
        .join(", ");
    let projection = if keys.is_empty() {
        String::new()
    } else {
        format!(", {columns}")
    };
    let mut sql = format!(
        "WITH new_rows AS (
            SELECT 'A' AS service, row_id, health_code{projection} FROM 'matching/new-A.parquet'
            UNION ALL
            SELECT 'B' AS service, row_id, health_code{projection} FROM 'matching/new-B.parquet'
         )"
    );
    if keys.is_empty() || !has_known_history {
        sql.push_str(
            " SELECT service, row_id, health_code, 0::BIGINT AS candidate_count,
                     NULL::UINTEGER AS predicted_token FROM new_rows",
        );
        return sql;
    }
    let group = keys.join(", ");
    // 過去の事故はすべて A で発生する。サービス別仮名では値と発行元の両方を照合する。
    let (issuer_column, match_keys) = if keys.contains(&"service_nickname") {
        ("'A' AS service, ", format!("service, {group}"))
    } else {
        ("", group.clone())
    };
    // row_id は事故ごとに再び0から始まるため、既知の過去行の結合には事故名も使う。
    sql.push_str(&format!(
        ", history AS (
            SELECT parse_filename(filename) AS incident, row_id, {columns}
            FROM read_parquet('matching/past-A-*.parquet', filename=true)
         ), known AS (
            SELECT parse_filename(filename) AS incident, row_id, identity_token
            FROM read_parquet('identity/past-A-*.parquet', filename=true)
         ), candidates AS (
            SELECT {issuer_column}{group}, count(DISTINCT identity_token) AS candidate_count,
                   min(identity_token) AS token
            FROM history JOIN known USING (incident, row_id)
            GROUP BY {group}
         )
         SELECT n.service, n.row_id, n.health_code,
                coalesce(c.candidate_count, 0) AS candidate_count,
                CASE WHEN c.candidate_count = 1 THEN c.token END AS predicted_token
         FROM new_rows n LEFT JOIN candidates c USING ({match_keys})"
    ));
    sql
}

fn summary_sql(predictions: &str, has_identity: bool) -> String {
    let roster = if has_identity {
        "SELECT identity_token, person_id FROM 'scoring/identity-roster.parquet'"
    } else {
        "SELECT NULL::UINTEGER AS identity_token, NULL::UINTEGER AS person_id WHERE false"
    };
    format!(
        "WITH truth AS (
            SELECT 'A' AS service, row_id, person_id, health_truth FROM 'scoring/new-A.parquet'
            UNION ALL
            SELECT 'B' AS service, row_id, person_id, health_truth FROM 'scoring/new-B.parquet'
         ), roster AS ({roster}), compared AS (
            SELECT service, row_id, p.candidate_count, p.predicted_token,
                   t.person_id AS truth_id, m.person_id AS predicted_id,
                   coalesce(t.person_id = m.person_id, false) AS correct,
                   p.health_code = t.health_truth AS health_matches
            FROM read_parquet({predictions}) p FULL OUTER JOIN truth t USING (service, row_id)
            LEFT JOIN roster m ON p.predicted_token = m.identity_token
         )
         SELECT service,
                CASE WHEN count(*) <> count(DISTINCT row_id)
                       OR count(*) <> count(candidate_count) OR count(*) <> count(truth_id)
                       OR count(predicted_token) <> count(predicted_id)
                     THEN error('予測と採点表の行または既知人物の対応が不整合です')
                     ELSE count(*) END AS targets,
                count(*) FILTER (WHERE correct) AS correct,
                count(*) FILTER (WHERE predicted_token IS NOT NULL AND NOT correct) AS incorrect,
                count(*) FILTER (WHERE predicted_token IS NULL) AS unresolved,
                bool_and(correct) AS all_correct,
                count(*) FILTER (WHERE correct AND health_matches) AS health_revealed
         FROM compared GROUP BY service ORDER BY service"
    )
}

pub fn score(args: &ScoreArgs, dir: &Path) -> Result<()> {
    let source = args
        .incidents
        .canonicalize()
        .context("反復ディレクトリを開けません")?;
    let staging = dir.canonicalize()?;
    let matching = source.join("matching");
    let past = history_files(&matching)?;
    let identity = source.join("identity");
    let has_identity = identity.try_exists()?;
    if has_identity {
        ensure!(
            history_files(&identity)? == past,
            "matching と identity で過去の事故ファイルが一致しません"
        );
    }

    let new_a = matching.join("new-A.parquet");
    let schema = ParquetReader::new(File::open(&new_a)?).schema()?;
    let name_mode = if schema.get_full("shared_nickname").is_some() {
        "shared"
    } else if schema.get_full("service_nickname").is_some() {
        "service"
    } else {
        "full"
    };
    let keys = key_columns(args.mask, name_mode)?;
    // 既知率0のときにも指定した列が履歴に記録された条件か確認する。
    if !has_identity && !keys.is_empty() {
        for file in &past {
            let path = matching.join(file);
            let schema = ParquetReader::new(File::open(&path)?).schema()?;
            for key in &keys {
                ensure!(
                    schema.get_full(key).is_some(),
                    "{} に必要な列 {key} がありません",
                    path.display()
                );
            }
        }
    }

    let executable =
        PathBuf::from(std::env::var_os("DUCKDB_BIN").unwrap_or_else(|| "duckdb".into()));
    let executable = if executable.components().count() > 1 {
        executable
            .canonicalize()
            .context("DUCKDB_BIN を参照できません")?
    } else {
        executable
    };
    let predictions = sql_path(&staging.join("predictions.parquet"))?;
    let predict = predict_sql(&keys, args.birth_year, has_identity && !past.is_empty());
    profile_copy(
        &executable,
        &source,
        &staging,
        "match-profile.json",
        &format!("COPY ({predict}) TO {predictions} (FORMAT PARQUET)"),
    )?;
    let report = summary_sql(&predictions, has_identity);
    profile_copy(
        &executable,
        &source,
        &staging,
        "score-profile.json",
        &format!(
            "COPY ({report}) TO {} (FORMAT CSV, HEADER)",
            sql_path(&staging.join("summary.csv"))?
        ),
    )
}
