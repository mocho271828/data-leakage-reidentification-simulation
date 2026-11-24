//! 一意のメールを含む3条件について、全国名簿から新規対象者に関わる抽選だけを行う。
//! 氏名は full、過去の本人対応と新規の健診記録率は100%、全属性の変化率は0%に固定する。
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use clap::Parser;
use rand::seq::{SliceRandom, index};
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha12Rng;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    population: usize,
    #[arg(long)]
    service_size: usize,
    #[arg(long)]
    overlap_count: usize,
    #[arg(long)]
    reuse_count: usize,
    #[arg(long)]
    license_holders: usize,
    /// グリッドに使う最大人数以上に固定すると、グリッドを変えても同じseedの抽出が一致する。
    #[arg(long, default_value_t = 100)]
    target_capacity: usize,
    #[arg(long)]
    first_seed: u64,
    #[arg(long)]
    repetitions: u32,
    #[arg(long)]
    grid: PathBuf,
    #[arg(long)]
    output: PathBuf,
}

#[derive(Clone, Copy, Ord, PartialOrd, Eq, PartialEq)]
struct Condition {
    percent: usize,
    size: usize,
    mask: usize,
}

fn rounded_size(service_size: usize, percent: usize) -> usize {
    ((service_size as u64 * percent as u64 + 50) / 100) as usize
}

fn read_grid(args: &Args) -> Result<BTreeMap<usize, BTreeSet<Condition>>> {
    let file = fs::read_to_string(&args.grid)?;
    let mut lines = file.lines();
    ensure!(
        lines.next() == Some("past_percent,past_count,new_size,mask"),
        "グリッドのヘッダが不正です"
    );
    let mut result = BTreeMap::<usize, BTreeSet<Condition>>::new();
    for (i, line) in lines.enumerate() {
        let fields = line
            .split(',')
            .map(str::parse)
            .collect::<Result<Vec<usize>, _>>()
            .with_context(|| format!("グリッド{}行目の整数が不正です", i + 2))?;
        let [percent, count, size, mask] = *fields.as_slice() else {
            anyhow::bail!("グリッド{}行目は4列必要です", i + 2)
        };
        ensure!(
            percent <= 100 && (count == 0 || rounded_size(args.service_size, percent) > 0),
            "過去の抽出人数が不正です"
        );
        ensure!(
            (1..=args.target_capacity).contains(&size) && matches!(mask, 2 | 3 | 31),
            "新規人数またはマスクが不正です"
        );
        ensure!(
            result.entry(count).or_default().insert(Condition {
                percent,
                size,
                mask
            }),
            "グリッドに重複した条件があります"
        );
    }
    ensure!(!result.is_empty(), "グリッドに測定条件がありません");
    Ok(result)
}

struct NewRow {
    person: usize,
    mail: usize,
}

struct Person {
    observed_token: usize,
    has_license: bool,
    best_past_rank: usize,
}

struct Trial {
    people: Vec<Person>,
    eligible_count: usize,
    /// 過去Aで使用するメールから既知の本人対応を引く。新規の正解は参照しない。
    past_mail: HashMap<usize, usize>,
    events: [Vec<NewRow>; 2],
    truth: Vec<usize>,
}

impl Trial {
    fn new(args: &Args, rng: &mut impl Rng) -> Self {
        let s = args.service_size;
        // 登録者の無作為な並べ替えを省略し、両サービスの共通部分を先頭に配置する。
        let a = index::sample(rng, s, args.target_capacity).into_vec();
        let b: Vec<_> = index::sample(rng, s, args.target_capacity)
            .into_iter()
            .map(|slot| {
                if slot < args.overlap_count {
                    slot
                } else {
                    s + slot - args.overlap_count
                }
            })
            .collect();
        let slots: BTreeSet<_> = a.iter().chain(&b).copied().collect();
        let n = slots.len();
        // 同一人物が両方の事故に選ばれた場合も、免許と過去登場歴の抽選は1人につき1回。
        let draws = index::sample(rng, args.population, n);
        let eligible_count = slots.range(..s).count();
        let mut tokens: Vec<_> = (0..n).collect();
        tokens.shuffle(rng);
        let mut mails: Vec<_> = (0..2 * n).collect();
        mails.shuffle(rng);
        let mut people = Vec::with_capacity(n);
        let mut lookup = HashMap::new();
        let mut past_mail = HashMap::new();
        for (i, (&slot, draw)) in slots.iter().zip(draws).enumerate() {
            lookup.insert(slot, i);
            if slot < s {
                past_mail.insert(mails[i], i);
            }
            people.push(Person {
                observed_token: tokens[i],
                has_license: draw < args.license_holders,
                best_past_rank: usize::MAX,
            });
        }
        let events = [(false, a), (true, b)].map(|(uses_b, event)| {
            event
                .into_iter()
                .map(|slot| {
                    let i = lookup[&slot];
                    let mail = if uses_b && slot >= args.reuse_count {
                        mails[n + i]
                    } else {
                        mails[i]
                    };
                    NewRow { person: i, mail }
                })
                .collect()
        });
        Self {
            people,
            eligible_count,
            past_mail,
            events,
            truth: tokens,
        }
    }

    fn add_incident(&mut self, service_size: usize, rng: &mut impl Rng) {
        // 一度の無作為順列のうち必要な人の順位だけを抽出。順位<h の人は h人事故に含まれる。
        // 異なる規模では同じ順位を使い、事故ごとには独立に引き直す。
        let ranks = index::sample(rng, service_size, self.eligible_count);
        for (person, rank) in self.people.iter_mut().zip(ranks) {
            person.best_past_rank = person.best_past_rank.min(rank);
        }
    }

    fn predict(
        &self,
        mail: usize,
        new_has_license: bool,
        mask: usize,
        past_size: usize,
    ) -> Option<usize> {
        let person = &self.people[*self.past_mail.get(&mail)?];
        // メールは一意。氏名・生年月日・住所も同じ本人では不変で、免許のNULLだけが追加の保留を生む。
        (person.best_past_rank < past_size
            && (mask != 31 || (new_has_license && person.has_license)))
            .then_some(person.observed_token)
    }

    fn score(&self, service: usize, cond: Condition, past_size: usize) -> (usize, usize, usize) {
        let mut correct = 0;
        let mut incorrect = 0;
        let mut seen = 0;
        for row in &self.events[service][..cond.size] {
            let person = &self.people[row.person];
            seen += usize::from(person.best_past_rank < past_size);
            if let Some(predicted) =
                self.predict(row.mail, person.has_license, cond.mask, past_size)
            {
                if predicted == self.truth[row.person] {
                    correct += 1;
                } else {
                    incorrect += 1;
                }
            }
        }
        (correct, incorrect, seen)
    }
}

fn main() -> Result<()> {
    let args = Args::parse();
    ensure!(
        args.population <= u32::MAX as usize && args.service_size <= u32::MAX as usize / 2,
        "人数が登録・人口コードの範囲外です"
    );
    ensure!(
        args.reuse_count <= args.overlap_count
            && args.overlap_count <= args.service_size
            && args.service_size * 2 - args.overlap_count <= args.population
            && args.license_holders <= args.population
            && (1..=args.service_size).contains(&args.target_capacity),
        "人口、登録者数、免許保有者数、または最大新規人数が整合しません"
    );
    ensure!(
        args.repetitions > 0
            && args
                .first_seed
                .checked_add(u64::from(args.repetitions - 1))
                .is_some(),
        "反復数またはシード範囲が不正です"
    );
    let grid = read_grid(&args)?;
    let parent = args
        .output
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    ensure!(!args.output.try_exists()?, "出力ファイルが既に存在します");
    let stage_dir = tempfile::tempdir_in(parent)?;
    let mut stage = tempfile::NamedTempFile::new_in(stage_dir.path())?;
    {
        let mut out = BufWriter::new(stage.as_file_mut());
        writeln!(
            out,
            "seed,past_percent,past_count,new_size,mask,service,correct,incorrect,unresolved,all_correct,health_revealed,seen_in_past,all_seen"
        )?;
        for trial in 0..args.repetitions {
            let seed = args.first_seed + u64::from(trial);
            let mut rng = ChaCha12Rng::seed_from_u64(seed);
            let mut data = Trial::new(&args, &mut rng);
            let mut current = 0;
            for (&k, conditions) in &grid {
                for _ in current..k {
                    data.add_incident(args.service_size, &mut rng);
                }
                current = k;
                for &c in conditions {
                    let past_size = rounded_size(args.service_size, c.percent);
                    for (service, label) in ["A", "B"].iter().enumerate() {
                        let (correct, wrong, seen) = data.score(service, c, past_size);
                        let unresolved = c.size - correct - wrong;
                        // 健診結果を全員に記録し値の誤りはないため、正答した本人の数に一致する。
                        writeln!(
                            out,
                            "{seed},{},{k},{},{},{label},{correct},{wrong},{unresolved},{},{correct},{seen},{}",
                            c.percent,
                            c.size,
                            c.mask,
                            u8::from(correct == c.size),
                            u8::from(seen == c.size)
                        )?;
                    }
                }
            }
        }
        out.flush()?;
    }
    stage.persist_noclobber(&args.output)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(holders: usize) -> Args {
        Args {
            population: 7,
            service_size: 5,
            overlap_count: 3,
            reuse_count: 2,
            license_holders: holders,
            target_capacity: 5,
            first_seed: 0,
            repetitions: 1,
            grid: PathBuf::new(),
            output: PathBuf::new(),
        }
    }

    fn measure(
        trial: &Trial,
        service: usize,
        mask: usize,
        past_size: usize,
    ) -> (usize, usize, usize) {
        trial.score(
            service,
            Condition {
                percent: 0,
                size: 5,
                mask,
            },
            past_size,
        )
    }

    #[test]
    fn full_rosters_count_overlap_and_mail_reuse_separately() {
        for holders in [0, 7] {
            let args = fixture(holders);
            let mut rng = ChaCha12Rng::seed_from_u64(9141);
            let mut trial = Trial::new(&args, &mut rng);
            assert_eq!(measure(&trial, 0, 31, 5), (0, 0, 0));
            trial.add_incident(5, &mut rng);
            for mask in [2, 3] {
                assert_eq!(measure(&trial, 0, mask, 3), (3, 0, 3));
                assert_eq!(measure(&trial, 1, mask, 5), (2, 0, 3));
            }
            assert_eq!(
                measure(&trial, 0, 31, 5),
                (if holders == 0 { 0 } else { 5 }, 0, 5)
            );
            assert_eq!(
                measure(&trial, 1, 31, 5),
                (if holders == 0 { 0 } else { 2 }, 0, 3)
            );
        }
    }

    #[test]
    fn predictions_are_independent_of_scoring_truth() {
        let mut rng = ChaCha12Rng::seed_from_u64(5183);
        let mut trial = Trial::new(&fixture(7), &mut rng);
        trial.add_incident(5, &mut rng);
        // 正解だけを書き換えても照合結果は同じで、採点では誤特定になる。
        trial.truth[trial.events[0][0].person] = usize::MAX;
        assert_eq!(measure(&trial, 0, 3, 5), (4, 1, 5));
    }
}
