use std::fs::{self, File};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use clap::Args;
use polars::prelude::*;
use serde::Deserialize;
use serde_json::json;

#[derive(Args)]
pub struct ProjectionArgs {
    /// incidents で生成した1反復分のディレクトリ
    #[arg(long)]
    incidents: PathBuf,
    /// 1=氏名または仮名、2=メール、4=生年月日、8=世帯住所、16=免許の和（0～31）
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=31))]
    mask: u8,
}

#[derive(Deserialize)]
struct SourceManifest {
    name_mode: String,
}

pub(super) fn key_columns(mask: u8, name_mode: &str) -> Result<Vec<&'static str>> {
    ensure!(
        mask <= 31,
        "マスクは0～31で指定してください（指定値 {mask}）"
    );
    let name_columns: &[&str] = match name_mode {
        "full" => &["surname_code", "given_name_code"],
        "shared" => &["shared_nickname"],
        "service" => &["service_nickname"],
        other => bail!("元の反復の name_mode に対応していません: {other}"),
    };
    let mut columns = Vec::new();
    if mask & 1 != 0 {
        columns.extend_from_slice(name_columns);
    }
    for (bit, name) in [
        (2, "mail_code"),
        (4, "birth_date"),
        (8, "household_code"),
        (16, "license_code"),
    ] {
        if mask & bit != 0 {
            columns.push(name);
        }
    }
    Ok(columns)
}

fn columns_for(mask: u8, name_mode: &str) -> Result<Vec<&'static str>> {
    let mut columns = vec!["row_id"];
    columns.extend(key_columns(mask, name_mode)?);
    columns.push("health_code");
    Ok(columns)
}

fn project_table(source: &Path, destination: &Path, columns: &[&str]) -> Result<()> {
    const BATCH_ROWS: usize = 65_536;

    let mut file =
        File::open(source).with_context(|| format!("入力を開けません: {}", source.display()))?;
    let mut reader = ParquetReader::new(&mut file);
    let schema = reader.schema()?;
    let mut projection = Vec::with_capacity(columns.len());
    for &name in columns {
        let (index, _, _) = schema
            .get_full(name)
            .with_context(|| format!("{} に必要な列 {name} がありません", source.display()))?;
        projection.push(index);
    }
    let metadata = reader.get_metadata()?.clone();
    let rows = metadata.num_rows;
    // 大きな新規事故も、指定列の1バッチだけを復号して元の行順のまま書く。
    let mut read_batch = |start| {
        let mut reader = ParquetReader::new(&mut file)
            .with_projection(Some(projection.clone()))
            .with_slice(Some((start, BATCH_ROWS.min(rows - start))));
        reader.set_metadata(metadata.clone());
        reader.finish()
    };
    let first = read_batch(0)?;
    let mut writer = ParquetWriter::new(File::create(destination)?).batched(first.schema())?;
    writer.write_batch(&first)?;
    drop(first);
    for start in (BATCH_ROWS..rows).step_by(BATCH_ROWS) {
        writer.write_batch(&read_batch(start)?)?;
    }
    writer.finish()?;
    Ok(())
}

pub fn generate(args: &ProjectionArgs, dir: &Path) -> Result<()> {
    let source = args
        .incidents
        .canonicalize()
        .context("元の反復ディレクトリを参照できません")?;
    let manifest_path = source.join("scoring/manifest.json");
    let source_manifest: SourceManifest = serde_json::from_reader(
        File::open(&manifest_path)
            .with_context(|| format!("{} を開けません", manifest_path.display()))?,
    )
    .with_context(|| format!("{} の name_mode を読み取れません", manifest_path.display()))?;
    let columns = columns_for(args.mask, &source_manifest.name_mode)?;
    let matching = dir.join("matching");
    fs::create_dir(&matching)?;
    for file in ["new-A.parquet", "new-B.parquet"] {
        project_table(
            &source.join("matching").join(file),
            &matching.join(file),
            &columns,
        )?;
    }
    let mut manifest = json!({
        "version": 1,
        "source_incidents": source,
        "source_manifest": "scoring/manifest.json",
        "source_past_files": "matching/past-A-*.parquet",
        "source_scoring_files": ["scoring/new-A.parquet", "scoring/new-B.parquet"],
        "new_mask": args.mask,
        "name_mode": source_manifest.name_mode,
        "new_columns": columns,
    });
    if source.join("identity").is_dir() {
        manifest["source_identity_files"] = json!("identity/past-A-*.parquet");
    }
    serde_json::to_writer_pretty(File::create(dir.join("manifest.json"))?, &manifest)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn all_masks_are_distinct_and_both_name_columns_move_together() -> Result<()> {
        let mut distinct = BTreeSet::new();
        for mask in 0..32 {
            let columns = columns_for(mask, "full")?;
            assert_eq!(columns.first(), Some(&"row_id"));
            assert_eq!(columns.last(), Some(&"health_code"));
            assert_eq!(columns.contains(&"surname_code"), mask & 1 != 0);
            assert_eq!(columns.contains(&"given_name_code"), mask & 1 != 0);
            distinct.insert(columns);
        }
        assert_eq!(distinct.len(), 32);
        assert_eq!(columns_for(0, "full")?, ["row_id", "health_code"]);
        assert!(columns_for(32, "full").is_err());
        Ok(())
    }

    #[test]
    fn parquet_projection_preserves_order_nulls_and_excludes_unrequested_columns() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let source = dir.path().join("source.parquet");
        let projected = dir.path().join("projected.parquet");
        let mut original = df!(
            "row_id" => [2_u32, 0, 1],
            "person_id" => [7_u32, 3, 2],
            "license_code" => [None, Some(41_u32), Some(75)],
            "health_code" => [1_u32, 0, 2],
        )?;
        ParquetWriter::new(File::create(&source)?).finish(&mut original)?;
        let columns = columns_for(16, "full")?;
        project_table(&source, &projected, &columns)?;
        let result = ParquetReader::new(File::open(&projected)?).finish()?;
        assert!(result.equals_missing(&original.select(columns)?));
        let missing = project_table(&source, &projected, &columns_for(1, "full")?).unwrap_err();
        assert!(missing.to_string().contains("surname_code"));
        Ok(())
    }

    #[test]
    fn generated_aliases_and_optional_identity_references_follow_the_source_manifest() -> Result<()>
    {
        for (mode, alias, with_identity) in [
            ("shared", "shared_nickname", true),
            ("service", "service_nickname", false),
        ] {
            let source = tempfile::tempdir()?;
            let output = tempfile::tempdir()?;
            let root = source.path();
            fs::create_dir(root.join("matching"))?;
            fs::create_dir(root.join("scoring"))?;
            if with_identity {
                fs::create_dir(root.join("identity"))?;
            }
            serde_json::to_writer(
                File::create(root.join("scoring/manifest.json"))?,
                &json!({"name_mode": mode}),
            )?;
            let mut frame = df!(
                "row_id" => [1_u32, 0], alias => [715_u32, 312],
                "birth_date" => [0_i32, 365], "health_code" => [2_u32, 1],
            )?;
            for file in ["new-A.parquet", "new-B.parquet"] {
                ParquetWriter::new(File::create(root.join("matching").join(file))?)
                    .finish(&mut frame)?;
            }
            let args = ProjectionArgs {
                incidents: root.into(),
                mask: 1,
            };
            generate(&args, output.path())?;
            let expected = frame.select(["row_id", alias, "health_code"])?;
            for file in ["new-A.parquet", "new-B.parquet"] {
                let result =
                    ParquetReader::new(File::open(output.path().join("matching").join(file))?)
                        .finish()?;
                assert!(result.equals_missing(&expected));
            }
            let manifest: serde_json::Value =
                serde_json::from_reader(File::open(output.path().join("manifest.json"))?)?;
            assert_eq!(manifest["name_mode"], mode);
            assert_eq!(
                manifest["new_columns"],
                json!(["row_id", alias, "health_code"])
            );
            assert_eq!(
                manifest
                    .get("source_identity_files")
                    .and_then(|v| v.as_str()),
                with_identity.then_some("identity/past-A-*.parquet"),
            );
            assert_eq!(columns_for(0, mode)?, ["row_id", "health_code"]);

            let mut missing = frame.drop(alias)?;
            ParquetWriter::new(File::create(root.join("matching/new-B.parquet"))?)
                .finish(&mut missing)?;
            let incomplete = tempfile::tempdir()?;
            let err = generate(&args, incomplete.path()).unwrap_err().to_string();
            assert!(err.contains("new-B.parquet") && err.contains(alias));
        }
        Ok(())
    }

    #[test]
    fn empty_and_multi_batch_files_retain_every_row() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let source = dir.path().join("source.parquet");
        let projected = dir.path().join("projected.parquet");
        for size in [0, 70_003_u32] {
            let ids: Vec<_> = (0..size).rev().collect();
            let mut original = df!("row_id" => &ids, "health_code" => &ids)?;
            ParquetWriter::new(File::create(&source)?)
                .with_row_group_size(Some(10_000))
                .finish(&mut original)?;
            project_table(&source, &projected, &columns_for(0, "full")?)?;
            let result = ParquetReader::new(File::open(&projected)?).finish()?;
            assert!(result.equals_missing(&original));
        }
        Ok(())
    }
}
