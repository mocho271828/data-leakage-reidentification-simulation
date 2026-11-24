use std::{fs, path::Path};

use anyhow::{Result, ensure};
use polars::prelude::*;
use rand::{Rng, seq::SliceRandom};

use super::{output::table, population::Person, registrations::Account, stream};

pub(super) struct IdentityDirectory {
    tokens: Vec<u32>,
}

impl IdentityDirectory {
    pub(super) fn new(people: &[Person], dir: &Path, seed: u64) -> Result<Self> {
        let mut tokens: Vec<u32> = (0..u32::try_from(people.len())?).collect();
        tokens.shuffle(&mut stream(seed, u64::MAX));
        fs::create_dir(dir.join("identity"))?;
        table(
            &dir.join("scoring/identity-roster.parquet"),
            people.len(),
            |range| {
                df!(
                    "person_id" => people[range.clone()].iter().map(|p| p.person_id).collect::<Vec<_>>(),
                    "identity_token" => &tokens[range]
                )
            },
        )?;
        Ok(Self { tokens })
    }

    pub(super) fn past(
        &self,
        dir: &Path,
        name: &str,
        sample: &[u32],
        accounts: &[Account],
        percent: u8,
        rng: &mut impl Rng,
    ) -> Result<u32> {
        ensure!(percent <= 100, "本人対応済みの行の割合が100%を超えています");
        let mut count = 0;
        table(&dir.join("identity").join(name), sample.len(), |range| {
            let mut row_ids = Vec::new();
            let mut known_tokens = Vec::new();
            for index in range {
                if rng.random_ratio(u32::from(percent), 100) {
                    let account = &accounts[sample[index] as usize];
                    row_ids.push(index as u32);
                    known_tokens.push(self.tokens[account.person_index]);
                }
            }
            count += row_ids.len();
            df!("row_id" => row_ids, "identity_token" => known_tokens)
        })?;
        Ok(u32::try_from(count)?)
    }
}
