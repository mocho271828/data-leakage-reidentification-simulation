use anyhow::{Result, ensure};
use clap::ValueEnum;
use rand::Rng;
use rand_distr::weighted::WeightedTreeIndex;
use serde::{Deserialize, Serialize};

use crate::apportion::apportion;

/// 明治安田生命「全国同姓調査」2018年、表1・表2（各順位の占率、0.01%単位）。
/// https://www.meijiyasuda.co.jp/profile/news/release/2018/pdf/20180808_01.pdf
#[rustfmt::skip]
const TOP_TEN_BASIS_POINTS: [u32; 10] = [
    153, 144, 114, 106, 94, 90, 85, 83, 82, 71,
];

#[rustfmt::skip]
const NEXT_NINETY_BASIS_POINTS: [u32; 90] = [
    68, 65, 55, 51, 50, 48, 48, 46, 44, 43,
    39, 38, 38, 37, 36, 36, 34, 33, 33, 33,
    32, 31, 30, 30, 30, 30, 29, 28, 28, 28,
    27, 25, 25, 25, 24, 24, 24, 24, 23, 23,
    23, 23, 23, 23, 23, 22, 22, 21, 21, 21,
    20, 20, 20, 20, 20, 19, 19, 19, 19, 19,
    18, 18, 18, 18, 17, 17, 17, 17, 17, 17,
    17, 16, 16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 15, 15, 15, 15, 15,
];

const PREFECTURES: usize = 47;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum TailShape {
    Even,
    ManyRare,
}

pub fn assumptions() -> serde_json::Value {
    serde_json::json!({
        "surname_source": {
            "title": "明治安田生命「全国同姓調査」表1・表2",
            "url": "https://www.meijiyasuda.co.jp/profile/news/release/2018/pdf/20180808_01.pdf",
            "scope": "2018年5月時点の個人保険・個人年金保険の契約者6,557,813人。2018年7月調査。この契約者標本の構成を、外国人を含む国内の15～64歳全体の近似として使う。",
            "top10_percent": 10.22,
            "top100_percent": 33.38,
            "rounding": "人口×累積占率を四捨五入。1～10位と11～100位をそれぞれ、各順位の公表占率に比例して最大剰余法で整数配分する。同じ剰余では上位を優先する。"
        },
        "surname_tail": {
            "kinds": "101位以下の人数をTとする。ceil(T/8)を1,000～100,000に収め、さらにTを上限とする。両条件で種類数を固定する。",
            "even": "各姓の人数差を1人以内にする。",
            "many-rare": "種類数の半分（端数切り捨て）を各1人の姓とし、残りは人数差1人以内にする。",
            "origin": "実験仮定。小規模で尾部が1,000人以下の場合、両条件とも尾部は1人1姓になる。"
        },
        "surname_assignment": "同居人には指定確率で世帯先頭者の姓を再利用する。共有しない場合、または姓の残数が尽きた場合は残数に比例して抽選する。地域優先時は姓コード順に47地域に巡回配分した該当地域の姓から選び、尽きたら全国から選ぶ。基準条件では地域を優先しない。",
        "given_name": {
            "origin": "模擬コードと混合割合は実験仮定。",
            "all_cohorts": "35%は全世代共通の1～512から一様抽選。",
            "per_cohort": "65%は15～19歳を先頭とする5歳階級ごとに256種類から一様抽選。初期コードは513、階級ごとに開始コードを128ずらす。"
        }
    })
}

fn quotas(population: u32, tail: TailShape) -> Vec<u32> {
    let rounded_count =
        |basis_points: u64| ((u64::from(population) * basis_points + 5_000) / 10_000) as u32;
    let top_10 = rounded_count(1_022);
    let top_100 = rounded_count(3_338);
    let mut counts = apportion(top_10, &TOP_TEN_BASIS_POINTS).to_vec();
    counts.extend(apportion(top_100 - top_10, &NEXT_NINETY_BASIS_POINTS));

    let tail_total = population - top_100;
    if tail_total == 0 {
        return counts;
    }
    // 実験仮定。小規模でも二条件の種類数をそろえ、全規模で各尾部コードを1回以上使う。
    let kinds = tail_total.div_ceil(8).clamp(1_000, 100_000).min(tail_total);
    let singletons = match tail {
        TailShape::Even => 0,
        TailShape::ManyRare => kinds / 2,
    };
    let other_kinds = kinds - singletons;
    let other_people = tail_total - singletons;
    counts.extend(
        (0..other_kinds)
            .map(|i| other_people / other_kinds + u32::from(i < other_people % other_kinds)),
    );
    counts.extend(std::iter::repeat_n(1, singletons as usize));
    counts
}

pub struct Names {
    quota: Vec<u32>,
    region_totals: WeightedTreeIndex<u32>,
    per_region: Vec<WeightedTreeIndex<u32>>,
}

impl Names {
    pub fn new(population: u32, tail: TailShape) -> Result<Self> {
        ensure!(population > 0, "人口は1人以上を指定してください");
        let quota = quotas(population, tail);
        // コード順に47地域へ巡回配分する。優先地域がない場合も全国の残数に厳密に比例する。
        let mut per_region = Vec::with_capacity(PREFECTURES);
        let mut region_totals = Vec::with_capacity(PREFECTURES);
        for region in 0..PREFECTURES {
            let weights = quota.iter().skip(region).step_by(PREFECTURES).copied();
            region_totals.push(weights.clone().sum::<u32>());
            per_region.push(WeightedTreeIndex::new(weights)?);
        }
        Ok(Self {
            quota,
            per_region,
            region_totals: WeightedTreeIndex::new(region_totals)?,
        })
    }

    /// 配列の要素 i は姓コード i+1 を持つ予定人数。
    pub fn quota(&self) -> &[u32] {
        &self.quota
    }

    /// household_surname は同一世帯の先頭者のコード。共有・地域優先とも姓の残数を守る。
    pub fn surname(
        &mut self,
        rng: &mut impl Rng,
        household_surname: Option<u32>,
        share_probability: f64,
        preferred_prefecture: Option<u32>,
    ) -> Result<u32> {
        ensure!(
            (0.0..=1.0).contains(&share_probability),
            "世帯内同姓の指定確率は0から1です"
        );
        if let Some(pref) = preferred_prefecture {
            ensure!(
                (1..=PREFECTURES as u32).contains(&pref),
                "都道府県コードは1から47です"
            );
        }
        let mut shared = None;
        if let Some(code) = household_surname {
            ensure!(
                (1..=self.quota.len() as u32).contains(&code),
                "不正な世帯の姓コードです"
            );
            let index = code as usize - 1;
            let pair = (index % PREFECTURES, index / PREFECTURES);
            if rng.random_bool(share_probability) && self.per_region[pair.0].get(pair.1) > 0 {
                shared = Some(pair);
            }
        }
        let (region, local_index) = match shared {
            Some(pair) => pair,
            None => {
                let preferred = preferred_prefecture.map(|p| (p - 1) as usize);
                let region = match preferred.filter(|&r| self.per_region[r].is_valid()) {
                    Some(r) => r,
                    None => self.region_totals.try_sample(rng)?,
                };
                (region, self.per_region[region].try_sample(rng)?)
            }
        };
        let region_left = self.region_totals.get(region) - 1;
        self.region_totals.update(region, region_left)?;
        let name_tree = &mut self.per_region[region];
        name_tree.update(local_index, name_tree.get(local_index) - 1)?;
        Ok((local_index * PREFECTURES + region + 1) as u32)
    }
}

/// 35%は全世代共通の512種類、65%は5歳階級ごとの256種類。隣り合う階級は128種類を共有する。
pub fn given_name(rng: &mut impl Rng, age: u32) -> u32 {
    if rng.random_bool(0.35) {
        rng.random_range(1..=512)
    } else {
        let cohort = (age - 15) / 5;
        513 + 128 * cohort + rng.random_range(0..256)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::{SeedableRng, rngs::StdRng};

    #[test]
    fn published_totals_and_tail_size_hold_for_both_shapes() {
        let even = quotas(73_322_000, TailShape::Even);
        let rare = quotas(73_322_000, TailShape::ManyRare);
        for counts in [&even, &rare] {
            assert_eq!(counts.iter().sum::<u32>(), 73_322_000);
            assert_eq!(counts[..10].iter().sum::<u32>(), 7_493_508);
            assert_eq!(counts[..100].iter().sum::<u32>(), 24_474_884);
            assert_eq!(counts.len(), 100_100);
            assert!(counts.iter().all(|&n| n > 0));
            assert!(counts[100] <= counts[99]);
        }
        assert_eq!(rare.iter().filter(|&&n| n == 1).count(), 50_000);
        assert_eq!(even.iter().filter(|&&n| n == 1).count(), 0);
    }

    #[test]
    fn household_and_region_preferences_do_not_change_quotas() -> Result<()> {
        let mut names = Names::new(20_000, TailShape::ManyRare)?;
        let mut rng = StdRng::seed_from_u64(26);
        let mut actual = vec![0; names.quota().len()];
        let mut head = None;
        for i in 0..20_000 {
            if i % 4 == 0 {
                head = None;
            }
            let code = names.surname(&mut rng, head, 0.8, Some(1))?;
            head.get_or_insert(code);
            actual[code as usize - 1] += 1;
        }
        assert_eq!(actual, names.quota());
        assert!(names.surname(&mut rng, None, 0.8, None).is_err());
        Ok(())
    }
}
