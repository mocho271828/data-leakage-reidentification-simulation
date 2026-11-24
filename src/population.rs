use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::BufWriter;
use std::path::Path;

use anyhow::{Context, Result, ensure};
use clap::Args;
use polars::prelude::*;
use rand::{Rng, SeedableRng, seq::SliceRandom};
use rand_chacha::ChaCha8Rng;
use serde_json::json;

use crate::demography::{NATIONAL_POPULATION, PopulationSampler};
use crate::households::{self, Household, Households};
use crate::names::{self, Names, TailShape};

#[derive(Args)]
pub struct PopulationArgs {
    /// 人口。全国規模は73322000人
    #[arg(long, default_value_t = 10_000, value_parser = clap::value_parser!(u32).range(1..=NATIONAL_POPULATION as i64))]
    pub people: u32,
    /// 人口を再現する乱数シード
    #[arg(long, default_value_t = 2026)]
    seed: u64,
    /// 1つのParquetファイルに書き出す最大人数
    #[arg(long, default_value_t = 100_000, value_parser = clap::value_parser!(u32).range(1..))]
    chunk_size: u32,
    /// 101位以降の姓の人数配分
    #[arg(long, value_enum, default_value = "many-rare")]
    tail: TailShape,
    /// 世帯の2人目以降が先頭の姓を優先する確率
    #[arg(long, default_value_t = 0.8)]
    household_surname_share: f64,
    /// 全国の姓の人数を保ちながら、居住地域に対応する姓を優先する確率
    #[arg(long, default_value_t = 0.0)]
    regional_surname_share: f64,
}

fn stream(seed: u64, stream_id: u64) -> ChaCha8Rng {
    let mut rng = ChaCha8Rng::seed_from_u64(seed);
    rng.set_stream(stream_id);
    rng
}

/// 保有者の発行順を32ビットの全単射で並べ替える。全員分の番号の保存を避ける。
struct LicenseCodes {
    tables: [Vec<u16>; 3],
    issued: u32,
}

impl LicenseCodes {
    fn new(rng: &mut impl Rng) -> Self {
        let tables = std::array::from_fn(|_| {
            let mut table: Vec<_> = (0..=u16::MAX).collect();
            table.shuffle(rng);
            table
        });
        Self { tables, issued: 0 }
    }

    fn issue(&mut self) -> u32 {
        let mut high = (self.issued >> 16) as u16;
        let mut low = self.issued as u16;
        for table in &self.tables {
            (high, low) = (low, high ^ table[usize::from(low)]);
        }
        self.issued += 1;
        (u32::from(high) << 16) | u32::from(low)
    }
}

#[derive(Default)]
struct Chunk {
    person: Vec<u32>,
    japanese: Vec<bool>,
    birth: Vec<i32>,
    household: Vec<u32>,
    town: Vec<u32>,
    municipality: Vec<u32>,
    prefecture: Vec<u32>,
    surname: Vec<u32>,
    given: Vec<u32>,
    license: Vec<Option<u32>>,
}

impl Chunk {
    fn push(
        &mut self,
        person: u32,
        demographic: &crate::demography::Demographic,
        household: &Household,
        surname: u32,
        given: u32,
        license: Option<u32>,
    ) {
        self.person.push(person);
        self.japanese.push(demographic.is_japanese);
        self.birth.push(demographic.birth_date.to_epoch_days());
        self.household.push(household.household_code);
        self.town.push(household.town_code);
        self.municipality.push(household.municipality_code);
        self.prefecture.push(household.prefecture_code);
        self.surname.push(surname);
        self.given.push(given);
        self.license.push(license);
    }

    fn write(self, folder: &Path, index: u32) -> Result<()> {
        let path = folder.join(format!("part-{index:05}.parquet"));
        let mut frame = df!(
            "person_id" => self.person, "is_japanese" => self.japanese,
            "birth_date" => self.birth, "household_code" => self.household,
            "town_code" => self.town, "municipality_code" => self.municipality,
            "prefecture_code" => self.prefecture, "surname_code" => self.surname,
            "given_name_code" => self.given, "license_code" => self.license
        )?;
        ParquetWriter::new(File::create(&path)?)
            .finish(&mut frame)
            .with_context(|| format!("人口Parquetの書き出し: {}", path.display()))?;
        Ok(())
    }
}

pub fn generate(args: &PopulationArgs, dir: &Path) -> Result<()> {
    for probability in [args.household_surname_share, args.regional_surname_share] {
        ensure!(
            (0.0..=1.0).contains(&probability),
            "姓の共有・地域優先の確率は0〜1を指定してください"
        );
    }
    let folder = dir.join("scoring/population");
    fs::create_dir_all(&folder)?;
    let mut demographic_rng = stream(args.seed, 0);
    let mut household_rng = stream(args.seed, 1);
    let mut surname_rng = stream(args.seed, 2);
    let mut given_rng = stream(args.seed, 3);
    let mut population = PopulationSampler::new(args.people);
    let mut households = Households::new(&mut household_rng);
    let mut names = Names::new(args.people, args.tail)?;
    let mut codes = LicenseCodes::new(&mut stream(args.seed, 4));
    let mut surname_counts = vec![0u32; names.quota().len()];
    let mut household_sizes = BTreeMap::<u32, u32>::new();
    let mut housemates = 0u32;
    let mut shared_surnames = 0u32;
    let mut region_matches = 0u32;
    let mut chunk = Chunk::default();
    let mut part = 0;
    let mut next_id = 0;
    while next_id < args.people {
        let house = households.next_household(args.people - next_id, &mut household_rng);
        *household_sizes.entry(house.size).or_default() += 1;
        let mut first_surname = None;
        for _ in 0..house.size {
            let person = population
                .draw(&mut demographic_rng)
                .context("年齢階級の人数が不足しています")?;
            let pref = house.prefecture_code + 1;
            let regional = surname_rng
                .random_bool(args.regional_surname_share)
                .then_some(pref);
            let surname = names.surname(
                &mut surname_rng,
                first_surname,
                args.household_surname_share,
                regional,
            )?;
            let given = names::given_name(&mut given_rng, u32::from(person.age));
            let license = person.has_license.then(|| codes.issue());
            if let Some(first) = first_surname {
                housemates += 1;
                shared_surnames += u32::from(surname == first);
            } else {
                first_surname = Some(surname);
            }
            region_matches += u32::from((surname - 1) % 47 == house.prefecture_code);
            surname_counts[(surname - 1) as usize] += 1;
            chunk.push(next_id, &person, &house, surname, given, license);
            next_id += 1;
            if chunk.person.len() == args.chunk_size as usize || next_id == args.people {
                std::mem::take(&mut chunk).write(&folder, part)?;
                part += 1;
            }
        }
    }
    ensure!(
        surname_counts == names.quota(),
        "生成後の姓別人数が割当数と一致しません"
    );
    let mut bands = BTreeMap::<&str, (u32, u32)>::new();
    for &people in surname_counts.iter().filter(|&&n| n != 0) {
        let label = match people {
            1..=10 => "1-10",
            11..=100 => "11-100",
            101..=1000 => "101-1000",
            _ => "1001+",
        };
        let (kinds, persons) = bands.entry(label).or_default();
        *kinds += 1;
        *persons += people;
    }
    let manifest = json!({
        "dataset": "synthetic-population-v1",
        "population_size": args.people, "population_seed": args.seed,
        "chunk_size": args.chunk_size, "part_count": part,
        "birth_date_unit": "days since 1970-01-01", "demography": population.summary(),
        "household_assumptions": households::assumptions(),
        "households_by_eligible_size": household_sizes,
        "name_assumptions": names::assumptions(),
        "surname_tail": args.tail,
        "household_surname_share_requested": args.household_surname_share,
        "nonfirst_members": housemates, "nonfirst_members_with_first_surname": shared_surnames,
        "regional_surname_share_requested": args.regional_surname_share,
        "people_with_region_associated_surname": region_matches,
        "surname_top10_people": surname_counts[..10].iter().sum::<u32>(),
        "surname_top100_people": surname_counts[..100].iter().sum::<u32>(),
        "surname_count_bands_kinds_then_people": bands,
        "license_holders": codes.issued,
    });
    let mut file = BufWriter::new(File::create(dir.join("manifest.json"))?);
    serde_json::to_writer_pretty(&mut file, &manifest)?;
    std::io::Write::flush(&mut file)?;
    Ok(())
}
