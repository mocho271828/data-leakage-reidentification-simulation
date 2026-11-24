use anyhow::{Context, Result};
use polars::prelude::*;
use std::{fs::File, ops::Range, path::Path};

use super::{NameMode, population::Person, registrations::Account};

const BATCH_ROWS: usize = 65_536;

pub(super) fn table(
    path: &Path,
    rows: usize,
    mut batch: impl FnMut(Range<usize>) -> PolarsResult<DataFrame>,
) -> Result<()> {
    let first = batch(0..rows.min(BATCH_ROWS))?;
    let mut writer =
        ParquetWriter::new(File::create(path).with_context(|| path.display().to_string())?)
            .batched(first.schema())?;
    writer.write_batch(&first)?;
    for start in (BATCH_ROWS..rows).step_by(BATCH_ROWS) {
        writer.write_batch(&batch(start..(start + BATCH_ROWS).min(rows))?)?;
    }
    writer.finish()?;
    Ok(())
}

pub(super) struct Snapshots<'a> {
    pub people: &'a [Person],
    pub shared_aliases: &'a [u32],
    pub health: &'a [u8],
    pub recorded: &'a [bool],
}

impl Snapshots<'_> {
    pub fn roster(&self, path: &Path, accounts: &[Account]) -> Result<()> {
        table(path, accounts.len(), |range| {
            let rows = &accounts[range];
            df!(
                "person_id" => rows.iter().map(|a| self.people[a.person_index].person_id).collect::<Vec<_>>(),
                "mail_code" => rows.iter().map(|a| a.mail).collect::<Vec<_>>(),
                "shared_nickname" => rows.iter().map(|a| self.shared_aliases[a.person_index]).collect::<Vec<_>>(),
                "service_nickname" => rows.iter().map(|a| a.service_alias).collect::<Vec<_>>()
            )
        })
    }

    pub fn leak(&self, dir: &Path, name: &str, sample: &[u32], config: Leak<'_>) -> Result<()> {
        let resolve = |i: &u32| &config.accounts[*i as usize];
        table(&dir.join("scoring").join(name), sample.len(), |range| {
            let rows = &sample[range.clone()];
            let mut frame = df!(
                "row_id" => (range.start as u32..range.end as u32).collect::<Vec<_>>(),
                "person_id" => rows.iter().map(resolve).map(|a| self.people[a.person_index].person_id).collect::<Vec<_>>()
            )?;
            if config.is_new {
                frame.with_column(Column::new(
                    "health_truth".into(),
                    rows.iter()
                        .map(resolve)
                        .map(|a| u32::from(self.health[a.person_index]))
                        .collect::<Vec<_>>(),
                ))?;
            }
            Ok(frame)
        })?;
        table(&dir.join("matching").join(name), sample.len(), |range| {
            let row_ids = (range.start as u32..range.end as u32).collect::<Vec<_>>();
            let accounts = sample[range].iter().map(resolve);
            let people = accounts.clone().map(|a| &self.people[a.person_index]);
            let mut cols = vec![Column::new("row_id".into(), row_ids)];
            if config.mask & 1 != 0 {
                match config.name_mode {
                    NameMode::Full => {
                        cols.push(Column::new(
                            "surname_code".into(),
                            people.clone().map(|p| p.surname_code).collect::<Vec<_>>(),
                        ));
                        cols.push(Column::new(
                            "given_name_code".into(),
                            people
                                .clone()
                                .map(|p| p.given_name_code)
                                .collect::<Vec<_>>(),
                        ));
                    }
                    NameMode::Shared => cols.push(Column::new(
                        "shared_nickname".into(),
                        accounts
                            .clone()
                            .map(|a| self.shared_aliases[a.person_index])
                            .collect::<Vec<_>>(),
                    )),
                    NameMode::Service => cols.push(Column::new(
                        "service_nickname".into(),
                        accounts
                            .clone()
                            .map(|a| a.service_alias)
                            .collect::<Vec<_>>(),
                    )),
                }
            }
            if config.mask & 2 != 0 {
                cols.push(Column::new(
                    "mail_code".into(),
                    accounts.clone().map(|a| a.mail).collect::<Vec<_>>(),
                ));
            }
            if config.mask & 4 != 0 {
                cols.push(Column::new(
                    "birth_date".into(),
                    people.clone().map(|p| p.birth_date).collect::<Vec<_>>(),
                ));
            }
            if config.mask & 8 != 0 {
                cols.push(Column::new(
                    "household_code".into(),
                    people.clone().map(|p| p.household_code).collect::<Vec<_>>(),
                ));
            }
            if config.mask & 16 != 0 {
                cols.push(Column::new(
                    "license_code".into(),
                    people.map(|p| p.license_code).collect::<Vec<_>>(),
                ));
            }
            if config.is_new {
                cols.push(Column::new(
                    "health_code".into(),
                    accounts
                        .map(|a| {
                            self.recorded[a.person_index]
                                .then(|| u32::from(self.health[a.person_index]))
                        })
                        .collect::<Vec<_>>(),
                ));
            }
            DataFrame::new(cols)
        })
    }
}

pub(super) struct Leak<'a> {
    pub accounts: &'a [Account],
    pub mask: u8,
    pub name_mode: NameMode,
    pub is_new: bool,
}
