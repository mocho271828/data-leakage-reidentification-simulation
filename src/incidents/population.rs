use std::{fs::File, path::Path};

use anyhow::{Context, Result, ensure};
use polars::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
pub(super) struct PopulationMeta {
    pub(super) population_size: u32,
    pub(super) population_seed: u64,
    pub(super) chunk_size: u32,
}

#[derive(Debug)]
pub(super) struct Person {
    pub(super) person_id: u32,
    pub(super) surname_code: u32,
    pub(super) given_name_code: u32,
    pub(super) birth_date: i32,
    pub(super) household_code: u32,
    pub(super) license_code: Option<u32>,
}

pub(super) fn read_meta(root: &Path) -> Result<PopulationMeta> {
    let path = root.join("manifest.json");
    let file = File::open(&path).with_context(|| format!("{} を開けません", path.display()))?;
    let meta: PopulationMeta = serde_json::from_reader(file)
        .with_context(|| format!("{} の人口設定を読めません", path.display()))?;
    ensure!(meta.population_size > 0, "人口が0です");
    ensure!(meta.chunk_size > 0, "人口表のチャンクサイズが0です");
    Ok(meta)
}

/// 登録者が含まれるファイルだけを読み、入力と同じ人物ID順で属性を返す。
pub(super) fn read_selected(
    root: &Path,
    meta: &PopulationMeta,
    ids: &[u32],
) -> Result<Vec<Person>> {
    ensure!(meta.chunk_size > 0, "人口表のチャンクサイズが0です");
    ensure!(
        ids.windows(2).all(|pair| pair[0] < pair[1]),
        "抽出する人物IDは重複のない昇順で指定してください"
    );
    ensure!(
        ids.last().is_none_or(|&id| id < meta.population_size),
        "人口の範囲外の人物IDが指定されています"
    );
    let mut people = Vec::with_capacity(ids.len());
    for group in ids.chunk_by(|a, b| a / meta.chunk_size == b / meta.chunk_size) {
        let part = group[0] / meta.chunk_size;
        let start = part * meta.chunk_size;
        let end = start
            .saturating_add(meta.chunk_size)
            .min(meta.population_size);
        let path = root
            .join("scoring/population")
            .join(format!("part-{part:05}.parquet"));
        read_part(&path, start, end, group, &mut people)
            .with_context(|| format!("人口表 {} の読込に失敗しました", path.display()))?;
    }
    Ok(people)
}

fn read_part(
    path: &Path,
    start: u32,
    end: u32,
    ids: &[u32],
    people: &mut Vec<Person>,
) -> Result<()> {
    let columns = [
        "person_id",
        "surname_code",
        "given_name_code",
        "birth_date",
        "household_code",
        "license_code",
    ];
    let frame = ParquetReader::new(File::open(path)?)
        .with_columns(Some(columns.map(str::to_owned).into()))
        .set_rechunk(true)
        .finish()?;
    ensure!(
        frame.height() == (end - start) as usize,
        "チャンクの人数が人口設定と一致しません"
    );
    let required_u32 = |name: &str| -> Result<&[u32]> {
        frame
            .column(name)?
            .u32()?
            .cont_slice()
            .with_context(|| format!("{name} に欠損があります"))
    };
    ensure!(
        required_u32("person_id")?.iter().copied().eq(start..end),
        "チャンクの人物IDが想定範囲 {start}..{end} の連番と一致しません"
    );
    let surnames = required_u32("surname_code")?;
    let given_names = required_u32("given_name_code")?;
    let households = required_u32("household_code")?;
    let birth_dates = frame
        .column("birth_date")?
        .i32()?
        .cont_slice()
        .context("birth_date に欠損があります")?;
    let licenses = frame.column("license_code")?.u32()?;
    for &person_id in ids {
        let index = (person_id - start) as usize;
        people.push(Person {
            person_id,
            surname_code: surnames[index],
            given_name_code: given_names[index],
            birth_date: birth_dates[index],
            household_code: households[index],
            license_code: licenses.get(index),
        });
    }
    Ok(())
}
