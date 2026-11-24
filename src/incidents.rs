mod identity;
mod output;
mod population;
mod registrations;
mod sampling;

use std::fs::{self, File};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use chrono::{Days, NaiveDate};
use clap::{Args, ValueEnum};
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha12Rng;
use serde::Serialize;
use serde_json::json;

use self::output::{Leak, Snapshots};
use self::registrations::Registrations;

#[derive(Clone, Copy, ValueEnum, Serialize)]
#[serde(rename_all = "lowercase")]
enum NameMode {
    Full,
    Shared,
    Service,
}

#[derive(Args)]
pub struct IncidentArgs {
    /// population サブコマンドの出力ディレクトリ
    #[arg(long)]
    population: PathBuf,
    /// A・Bそれぞれの登録人数。既定は人口の半分（切り上げ）、上限1万人
    #[arg(long)]
    service_size: Option<u32>,
    /// B登録者のうちAにも登録する割合（%、人数に四捨五入）
    #[arg(long, default_value_t = 50, value_parser = clap::value_parser!(u8).range(0..=100))]
    overlap_percent: u8,
    /// 共通登録者のうち両サービスで同じメールを使う割合（%）
    #[arg(long, default_value_t = 50, value_parser = clap::value_parser!(u8).range(0..=100))]
    mail_reuse_percent: u8,
    /// サービスAで順番に発生する過去の事故件数
    #[arg(long, default_value_t = 2)]
    past_incidents: u32,
    /// 過去1事故当たりの人数。既定は登録者数と10の小さい方
    #[arg(long)]
    past_size: Option<u32>,
    /// 新規A・Bの各事故の人数。既定は登録者数と10の小さい方
    #[arg(long)]
    new_size: Option<u32>,
    /// 新規側の保存列。1=氏名、2=メール、4=生年月日、8=世帯住所、16=免許の和
    #[arg(long, default_value_t = 31, value_parser = clap::value_parser!(u8).range(0..=31))]
    new_mask: u8,
    /// 過去側の保存列。ビットの意味は --new-mask と同じ
    #[arg(long, default_value_t = 31, value_parser = clap::value_parser!(u8).range(0..=31))]
    past_mask: u8,
    /// 人物ごとに決める健診結果の記録確率（%、結果が空欄でも新規の行に含む）
    #[arg(long, default_value_t = 100, value_parser = clap::value_parser!(u8).range(0..=100))]
    health_recorded_percent: u8,
    /// 各過去行に対して照合者が名簿上の本人を知っている確率（%）
    #[arg(long, default_value_t = 0, value_parser = clap::value_parser!(u8).range(0..=100))]
    known_identity_percent: u8,
    /// 過去・新規で氏名を保存する際の表現（氏名、共通仮名、サービス別仮名）
    #[arg(long, value_enum, default_value = "full")]
    name_mode: NameMode,
    /// サービスと履歴を抽選する反復用の乱数種
    #[arg(long, default_value_t = 20261123)]
    seed: u64,
}

fn stream(seed: u64, stream_id: u64) -> ChaCha12Rng {
    let mut rng = ChaCha12Rng::seed_from_u64(seed);
    rng.set_stream(stream_id);
    rng
}

fn rounded_count(n: u32, percent: u8) -> u32 {
    ((u64::from(n) * u64::from(percent) + 50) / 100) as u32
}

pub fn generate(args: &IncidentArgs, dir: &Path) -> Result<()> {
    let meta = population::read_meta(&args.population)?;
    let size = args
        .service_size
        .unwrap_or_else(|| meta.population_size.div_ceil(2).min(10_000));
    let overlap = rounded_count(size, args.overlap_percent);
    let reuse = rounded_count(overlap, args.mail_reuse_percent);
    let past_size = args.past_size.unwrap_or(size.min(10));
    let new_size = args.new_size.unwrap_or(size.min(10));
    ensure!(size > 0, "各サービスに1人以上の登録者が必要です");
    ensure!(
        size <= u32::MAX / 2,
        "架空コードは両サービスで合計32ビットの範囲に収めてください"
    );
    ensure!(
        (1..=size).contains(&new_size),
        "新規事故人数は1以上かつ登録者数以下にしてください"
    );
    ensure!(
        past_size <= size && (args.past_incidents == 0 || past_size > 0),
        "過去事故人数が登録者数と整合しません"
    );
    let date = NaiveDate::from_ymd_opt(2026, 5, 1).expect("有効な基準日");
    let new_date = date
        .checked_add_days(Days::new(u64::from(args.past_incidents)))
        .context("指定事故件数が日付の範囲を超えています")?;

    let (a, b) = sampling::rosters(
        meta.population_size,
        size,
        overlap,
        &mut stream(args.seed, 0),
    )?;
    let regs = Registrations::new(a, b, reuse, &mut stream(args.seed, 1))?;
    let people = population::read_selected(&args.population, &meta, &regs.people)?;
    let mut health_rng = stream(args.seed, 2);
    let health: Vec<u8> = (0..people.len())
        .map(|_| health_rng.random_range(0..3))
        .collect();
    let mut attendance_rng = stream(args.seed, u64::MAX - 1);
    let recorded: Vec<bool> = (0..people.len())
        .map(|_| attendance_rng.random_range(0u8..100) < args.health_recorded_percent)
        .collect();
    let snapshots = Snapshots {
        people: &people,
        shared_aliases: &regs.shared_aliases,
        health: &health,
        recorded: &recorded,
    };

    let scoring = dir.join("scoring");
    fs::create_dir(&scoring)?;
    fs::create_dir(dir.join("matching"))?;
    fs::copy(
        args.population.join("manifest.json"),
        scoring.join("population-manifest.json"),
    )
    .context("人口の生成条件を採点用ディレクトリに保存できません")?;
    snapshots.roster(&scoring.join("roster-A.parquet"), &regs.a)?;
    snapshots.roster(&scoring.join("roster-B.parquet"), &regs.b)?;
    let identity = (args.known_identity_percent > 0)
        .then(|| identity::IdentityDirectory::new(&people, dir, args.seed))
        .transpose()?;

    let mut seen = vec![false; people.len()];
    let mut past_without_license = 0u64;
    let mut past_known = 0u64;
    for i in 0..args.past_incidents {
        // 反復内で事故ごとに乱数ストリームを固定し、過去件数を増やしても既存の事故を再現する。
        let rows =
            sampling::sample_rows(size, past_size, &mut stream(args.seed, 5 + u64::from(i)))?;
        for &row in &rows {
            let index = regs.a[row as usize].person_index;
            seen[index] = true;
            past_without_license += u64::from(people[index].license_code.is_none());
        }
        let filename = format!("past-A-{:05}.parquet", i + 1);
        snapshots.leak(
            dir,
            &filename,
            &rows,
            Leak {
                accounts: &regs.a,
                mask: args.past_mask,
                name_mode: args.name_mode,
                is_new: false,
            },
        )?;
        if let Some(identity) = &identity {
            let mut rng = stream(args.seed, (1u64 << 33) + u64::from(i));
            past_known += u64::from(identity.past(
                dir,
                &filename,
                &rows,
                &regs.a,
                args.known_identity_percent,
                &mut rng,
            )?);
        }
    }

    let mut counts = Vec::new();
    for (service, accounts, stream_id) in [("A", &regs.a, 3), ("B", &regs.b, 4)] {
        let rows = sampling::sample_rows(size, new_size, &mut stream(args.seed, stream_id))?;
        let mut previously_seen = 0;
        let mut health_counts = [0u32; 3];
        let mut recorded_count = 0u32;
        let mut without_license = 0;
        for &row in &rows {
            let index = accounts[row as usize].person_index;
            previously_seen += u32::from(seen[index]);
            if recorded[index] {
                recorded_count += 1;
                health_counts[usize::from(health[index])] += 1;
            }
            without_license += u32::from(people[index].license_code.is_none());
        }
        snapshots.leak(
            dir,
            &format!("new-{service}.parquet"),
            &rows,
            Leak {
                accounts,
                mask: args.new_mask,
                name_mode: args.name_mode,
                is_new: true,
            },
        )?;
        counts.push(json!({
            "service": service,
            "service_size": size, "registrants_seen_in_past": accounts.iter().filter(|a| seen[a.person_index]).count(),
            "new_rows": new_size, "new_people_seen_in_past": previously_seen,
            "health_counts": health_counts, "health_recorded_count": recorded_count, "nonholders": without_license
        }));
    }

    let report = json!({
        "version": 1, "population": meta, "history_seed": args.seed,
        "population_root": args.population.canonicalize()?, "population_manifest_copy": "population-manifest.json",
        "registration": {
            "service_size": size, "overlap_percent": args.overlap_percent, "overlap_count": overlap,
            "mail_reuse_percent": args.mail_reuse_percent, "mail_reuse_denominator": overlap, "mail_reuse_count": reuse,
            "snapshot_date": date.to_string()
        },
        "history": {
            "service": "A", "incidents": args.past_incidents, "size_per_incident": past_size,
            "rows": u64::from(args.past_incidents) * u64::from(past_size),
            "distinct_people": seen.iter().filter(|&&flag| flag).count(), "nonholder_rows": past_without_license,
            "first_date": date.to_string(), "interval_days": 1, "mask": args.past_mask,
            "known_identity_percent": args.known_identity_percent, "known_rows": past_known
        },
        "new_incidents": counts, "new_date": new_date.to_string(), "new_mask": args.new_mask,
        "name_mode": args.name_mode,
        "assumptions": {
            "registration_changes_percent": 0, "individual_missing_percent": 0, "health_recorded_percent": args.health_recorded_percent,
            "health_codes": [0, 1, 2], "health_weights": [1, 1, 1],
            "sampling": "uniform_without_replacement_within_each_incident",
            "license_null_reason": "nonholder"
        }
    });
    serde_json::to_writer_pretty(File::create(scoring.join("manifest.json"))?, &report)?;
    Ok(())
}
