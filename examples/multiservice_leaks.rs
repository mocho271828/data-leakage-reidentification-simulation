//! 共通で一意のメールが本人に結び付くモデル。新規10人に関する過去の抽選を周辺化して測る。
use anyhow::{Result, ensure};
use clap::Parser;
use rand::seq::index;
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha12Rng;
use std::io::Write;
use std::path::{Path, PathBuf};

const TARGET_SIZE: usize = 10_000;
const SERVICE_SIZE: u32 = 1_000;
const NEW_SIZE: usize = 10;
const FIRST_SEED: u64 = 8_037_000;
const TRIALS: usize = 10_000;
const SCARCE: [(usize, usize); 4] = [(10, 1000), (20, 500), (100, 100), (1000, 10)];
const DENSE: [usize; 12] = [20, 50, 100, 130, 140, 150, 200, 280, 290, 300, 500, 1000];

#[derive(Parser)]
struct Args {
    /// 未作成のCSVファイル。親ディレクトリはあらかじめ作成する。
    #[arg(long)]
    output: PathBuf,
    /// 厳密境界の直前・直後の4配置を別シードで各200万回確認する。
    #[arg(long)]
    boundary_confirm: bool,
}

struct Layout {
    label: &'static str,
    overlap: Vec<usize>,
    services_by_target: Vec<Vec<usize>>,
}

impl Layout {
    fn new(label: &'static str, overlap: Vec<usize>) -> Self {
        Self {
            label,
            overlap,
            services_by_target: vec![vec![]; TARGET_SIZE],
        }
    }

    fn cyclic(k: usize, nested: bool) -> Self {
        let label = if nested { "nested" } else { "balanced" };
        let mut layout = Self::new(label, vec![SERVICE_SIZE as usize; k]);
        let pool = if nested {
            SERVICE_SIZE as usize
        } else {
            TARGET_SIZE
        };
        for service in 0..k {
            for slot in 0..SERVICE_SIZE as usize {
                let target = (service * SERVICE_SIZE as usize + slot) % pool;
                layout.services_by_target[target].push(service);
            }
        }
        layout
    }

    // 延べ1万人の系列専用。D人を各社に循環配置し、単独登録者は毎回別の人とする。
    fn endpoint(overlap: &[usize], d: usize, minimum_coverage: bool) -> Self {
        let label = match (d, minimum_coverage) {
            (0, _) => "disjoint",
            (_, true) => "min_coverage",
            (_, false) => "max_coverage",
        };
        let mut layout = Self::new(label, overlap.to_vec());
        let mut shared_per_service: Vec<_> = overlap.iter().map(|&c| c.min(d)).collect();
        if d > 0 && !minimum_coverage {
            // 最大被覆ではD人を2社ずつに割り当て、各社への割り当てを均す。
            shared_per_service.fill(0);
            for pos in 0..2 * d {
                shared_per_service[pos % overlap.len()] += 1;
            }
        }
        let mut shared_cursor = 0;
        let mut individual = d;
        for (service, (&c, shared)) in overlap.iter().zip(shared_per_service).enumerate() {
            assert!(shared <= c.min(d));
            for _ in 0..shared {
                layout.services_by_target[shared_cursor % d].push(service);
                shared_cursor += 1;
            }
            for _ in shared..c {
                layout.services_by_target[individual].push(service);
                individual += 1;
            }
        }
        layout
    }

    fn coverage(&self) -> (usize, usize) {
        let users = &self.services_by_target;
        (
            users.iter().filter(|s| !s.is_empty()).count(),
            users.iter().filter(|s| s.len() >= 2).count(),
        )
    }
}

#[derive(Default, Clone, Copy)]
struct ServiceDraw {
    processed: u32,
    hit120: u32,
    hit240: u32,
}

impl ServiceDraw {
    // 抽選順位を120人・次の120人・残り760人の3群に分け、残った枠数から非復元抽出する。
    fn observe(&mut self, position: u32) -> [bool; 2] {
        let hit120 = position < 120 - self.hit120;
        let hit240 = position < 240 - self.hit240;
        self.processed += 1;
        self.hit120 += u32::from(hit120);
        self.hit240 += u32::from(hit240);
        [hit120, hit240]
    }
}

fn trial(layout: &Layout, draws: &mut [ServiceDraw], seed: u64) -> [usize; 3] {
    draws.fill(ServiceDraw::default());
    let mut rng = ChaCha12Rng::seed_from_u64(seed);
    let mut correct = [0; 3];
    for target in index::sample(&mut rng, TARGET_SIZE, NEW_SIZE) {
        let services = &layout.services_by_target[target];
        let mut seen = [false; 2];
        for &service in services {
            let draw = &mut draws[service];
            let position = rng.random_range(0..SERVICE_SIZE - draw.processed);
            let hits = draw.observe(position);
            seen[0] |= hits[0];
            seen[1] |= hits[1];
        }
        correct[0] += usize::from(seen[0]);
        correct[1] += usize::from(seen[1]);
        correct[2] += usize::from(!services.is_empty());
    }
    correct
}

// scripts/repetition_results.rb と同じ、両側95% Wilson区間。
fn wilson(successes: usize, trials: usize) -> (f64, f64) {
    let n = trials as f64;
    let p = successes as f64 / n;
    let z: f64 = 1.959963984540054;
    let denom = 1.0 + z.powi(2) / n;
    let center = (p + z.powi(2) / (2.0 * n)) / denom;
    let radius = z / denom * (p * (1.0 - p) / n + z.powi(2) / (4.0 * n * n)).sqrt();
    (
        if successes == 0 { 0.0 } else { center - radius },
        if successes == trials {
            1.0
        } else {
            center + radius
        },
    )
}

fn ideal_probability(m: usize) -> f64 {
    if m < NEW_SIZE {
        return 0.0;
    }
    (0..NEW_SIZE)
        .map(|i| (m - i) as f64 / (TARGET_SIZE - i) as f64)
        .product()
}

fn measure(
    layout: Layout,
    profile: &str,
    first_seed: u64,
    trials: usize,
    out: &mut impl Write,
) -> Result<()> {
    let k = layout.overlap.len();
    let (m, d) = layout.coverage();
    let avg_overlap = layout.overlap.iter().sum::<usize>() / k;
    let mut successes = [0; 3];
    let mut totals = [0; 3];
    let mut draws = vec![ServiceDraw::default(); k];
    for i in 0..trials {
        for (j, correct) in trial(&layout, &mut draws, first_seed + i as u64)
            .into_iter()
            .enumerate()
        {
            successes[j] += usize::from(correct == NEW_SIZE);
            totals[j] += correct;
        }
    }
    for (j, percent) in [12, 24, 100].into_iter().enumerate() {
        let (low, high) = wilson(successes[j], trials);
        let rate = successes[j] as f64 / trials as f64;
        let mean = totals[j] as f64 / trials as f64;
        let decision = if low >= 0.8 {
            "reached"
        } else if high < 0.8 {
            "below"
        } else {
            "uncertain"
        };
        writeln!(
            out,
            "{k},{profile},{avg_overlap},{},{d},{m},{percent},{first_seed},{trials},{},{rate:.8},{low:.8},{high:.8},{decision},{mean:.4},{:.15e}",
            layout.label,
            successes[j],
            ideal_probability(m)
        )?;
    }
    Ok(())
}

fn explore(out: &mut impl Write) -> Result<()> {
    let equal = SCARCE.map(|(k, c)| (vec![c; k], "equal"));
    let mixed = [[50; 50], [150; 50]].concat();
    for (overlap, profile) in equal.into_iter().chain([(mixed, "half50_half150")]) {
        for (d, minimum) in [(0, true), (20, true), (20, false)] {
            measure(
                Layout::endpoint(&overlap, d, minimum),
                profile,
                FIRST_SEED,
                TRIALS,
                out,
            )?;
        }
    }
    for k in DENSE {
        for nested in [false, true] {
            measure(Layout::cyclic(k, nested), "equal", FIRST_SEED, TRIALS, out)?;
        }
    }
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();
    ensure!(!args.output.try_exists()?, "既存の出力ファイルを保護します");
    let parent = args
        .output
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut stage = tempfile::NamedTempFile::new_in(parent)?;
    writeln!(
        stage,
        "services,profile,mean_overlap,layout,d,m,leak_percent,first_seed,trials,all_correct,rate,lower95,upper95,decision,mean_correct,ideal_probability"
    )?;
    if args.boundary_confirm {
        for k in [139, 140, 298, 299] {
            measure(
                Layout::cyclic(k, false),
                "equal",
                9_100_000,
                2_000_000,
                &mut stage,
            )?;
        }
    } else {
        explore(&mut stage)?;
    }
    stage.flush()?;
    stage.persist_noclobber(args.output)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoints_have_the_requested_membership_counts() {
        for (k, c) in SCARCE {
            for d in [0, 20] {
                for minimum in [true, false] {
                    let layout = Layout::endpoint(&vec![c; k], d, minimum);
                    let m = if minimum {
                        d + k * c.saturating_sub(d)
                    } else {
                        k * c - d
                    };
                    assert_eq!(layout.coverage(), (m, d));
                    let mut counts = vec![0; k];
                    for services in layout.services_by_target {
                        assert!(services.windows(2).all(|pair| pair[0] < pair[1]));
                        for s in services {
                            counts[s] += 1;
                        }
                    }
                    assert_eq!(counts, vec![c; k]);
                }
            }
        }
    }

    #[test]
    fn two_draws_match_the_counts_of_ordered_pairs_in_a_full_roster() {
        let mut pair_counts = [[0u32; 3]; 3];
        for first in 0..SERVICE_SIZE {
            let mut draw = ServiceDraw::default();
            let [a, b] = draw.observe(first);
            for second in 0..SERVICE_SIZE - 1 {
                let mut rest = draw;
                let [c, d] = rest.observe(second);
                pair_counts[usize::from(a) + usize::from(b)][usize::from(c) + usize::from(d)] += 1;
            }
        }
        let groups = [760u32, 120, 120];
        for i in 0..3 {
            for j in 0..3 {
                assert_eq!(
                    pair_counts[i][j],
                    groups[i] * (groups[j] - u32::from(i == j))
                );
            }
        }
    }

    #[test]
    fn balanced_and_nested_have_expected_coverage() {
        for k in [20, 130] {
            let balanced = Layout::cyclic(k, false);
            assert!(
                balanced
                    .services_by_target
                    .iter()
                    .all(|v| v.len() == k / 10)
            );
            assert_eq!(balanced.coverage(), (10_000, 10_000));
            let nested = Layout::cyclic(k, true);
            assert_eq!(nested.coverage(), (1000, 1000));
        }
        assert!(ideal_probability(9779) < 0.8 && ideal_probability(9780) >= 0.8);
    }
}
