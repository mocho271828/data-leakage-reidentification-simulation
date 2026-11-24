//! 2020年国勢調査「人口等基本集計結果」表Ⅰ-4-2・表Ⅱ-1-1を用いた世帯モデル。
//! https://www.stat.go.jp/data/kokusei/2020/kekka/pdf/outline_01.pdf

use rand::Rng;
use rand::distr::{Distribution, weighted::WeightedIndex};

// 全年齢の一般世帯数。最後の区分（7人以上）は7人で代表させる。
const CENSUS_HOUSEHOLDS: [u32; 7] = [
    21_151_042, 15_656_588, 9_229_513, 6_629_815, 2_126_291, 629_499, 282_201,
];
const ELIGIBLE_SHARE: f64 = 0.595;
const PREFECTURES: u32 = 47;
const MUNICIPALITIES_PER_PREFECTURE: u32 = 32;
const TOWNS_PER_MUNICIPALITY: u32 = 64;

pub fn assumptions() -> serde_json::Value {
    serde_json::json!({
        "source": "https://www.stat.go.jp/data/kokusei/2020/kekka/pdf/outline_01.pdf",
        "source_date": "2020-10-01",
        "household_counts_by_total_size_1_through_7_plus": CENSUS_HOUSEHOLDS,
        "household_counts_scope": "表Ⅰ-4-2の全国一般世帯。7人以上は7人で近似する。",
        "working_age_probability_per_member": ELIGIBLE_SHARE,
        "age_assumption": "表Ⅱ-1-1の全国人口に占める15～64歳割合を世帯員ごとに独立に適用。対象者が0人の世帯を除き、最後の世帯は残人数を上限とする。",
        "prefectures": PREFECTURES,
        "municipalities_per_prefecture": MUNICIPALITIES_PER_PREFECTURE,
        "towns_per_municipality": TOWNS_PER_MUNICIPALITY,
        "geography_assumption": "世帯ごとに全架空町域から一様に選ぶ。"
    })
}

pub struct Household {
    pub size: u32,
    pub household_code: u32,
    pub town_code: u32,
    pub municipality_code: u32,
    pub prefecture_code: u32,
}

pub struct Households {
    sizes: WeightedIndex<u32>,
    next_code: u32,
    code_step: u32,
}

impl Households {
    pub fn new(rng: &mut impl Rng) -> Self {
        Self {
            sizes: WeightedIndex::new(CENSUS_HOUSEHOLDS).expect("positive census weights"),
            next_code: rng.random(),
            // 奇数ステップでu32全域を一巡し、人物の通し番号と別の一意な世帯コードを作る。
            code_step: rng.random::<u32>() | 1,
        }
    }

    /// 残りの対象者数の範囲で、15～64歳の人を含む世帯を一つ抽出する。
    pub fn next_household(&mut self, remaining_people: u32, rng: &mut impl Rng) -> Household {
        assert!(remaining_people > 0);
        let size = loop {
            let all_ages = 1 + self.sizes.sample(rng);
            // 59.5%は国勢調査の全国値。世帯員ごとの独立性は実験上の仮定。
            let eligible = (0..all_ages)
                .filter(|_| rng.random_bool(ELIGIBLE_SHARE))
                .count() as u32;
            if eligible != 0 {
                break eligible.min(remaining_people);
            }
        };
        let household_code = self.next_code;
        self.next_code = self.next_code.wrapping_add(self.code_step);
        let town_code = rng
            .random_range(0..PREFECTURES * MUNICIPALITIES_PER_PREFECTURE * TOWNS_PER_MUNICIPALITY);
        let municipality_code = town_code / TOWNS_PER_MUNICIPALITY;
        Household {
            size,
            household_code,
            town_code,
            municipality_code,
            prefecture_code: municipality_code / MUNICIPALITIES_PER_PREFECTURE,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;
    use std::collections::HashSet;

    #[test]
    fn households_fill_exact_population_with_unique_addresses() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut households = Households::new(&mut rng);
        let mut addresses = HashSet::new();
        let mut remaining = 10_000;
        let mut has_housemates = false;
        while remaining > 0 {
            let house = households.next_household(remaining, &mut rng);
            assert!((1..=7.min(remaining)).contains(&house.size));
            assert!(addresses.insert(house.household_code));
            assert!(house.prefecture_code < PREFECTURES);
            assert_eq!(
                house.town_code / TOWNS_PER_MUNICIPALITY,
                house.municipality_code
            );
            assert_eq!(
                house.municipality_code / MUNICIPALITIES_PER_PREFECTURE,
                house.prefecture_code
            );
            has_housemates |= house.size > 1;
            remaining -= house.size;
        }
        assert!(has_housemates);
        assert_eq!(households.next_household(1, &mut rng).size, 1);
    }
}
