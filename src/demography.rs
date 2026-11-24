use std::array;

use chrono::NaiveDate;
use rand::Rng;
use serde::Serialize;

use crate::apportion::apportion;

pub const NATIONAL_POPULATION: u32 = 73_322_000;
const JAPANESE_POPULATION: u32 = 69_873_000;
const REFERENCE_DATE: NaiveDate = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();

// 2026年10月報1ページ、5月1日現在の男女計。各行は15～19歳から60～64歳（千人）。
const JAPANESE_THOUSANDS: [u32; 10] = [5311, 5520, 5876, 5915, 6250, 7135, 8043, 9540, 8680, 7605];
const FOREIGN_THOUSANDS: [u32; 10] = [169, 688, 719, 524, 382, 282, 219, 180, 160, 124];

// 令和7年末の保有者（仮免許を除く）。15～19歳は各歳、20～64歳は5歳階級。
const YOUNG_HOLDERS: [u32; 5] = [0, 17_898, 41_998, 166_475, 536_360];
const ADULT_HOLDERS: [u32; 9] = [
    4_388_849, 5_327_355, 5_559_586, 6_051_007, 6_969_638, 7_874_659, 9_150_903, 8_018_473,
    7_104_829,
];
// 2026年6月報1ページ、年末の翌日（1月1日）現在の全国人口（千人）。
const JANUARY_THOUSANDS: [u32; 10] = [5469, 6195, 6569, 6416, 6668, 7457, 8376, 9777, 8641, 7842];

// 基準年の月日に満年齢 age になる最も新しい生年月日。
fn birthday_cutoff(year: i32, month: u32, age: usize) -> i32 {
    NaiveDate::from_ymd_opt(year - age as i32, month, 1)
        .unwrap()
        .to_epoch_days()
}

fn license_probabilities() -> [f64; 50] {
    let youngest_band_days = birthday_cutoff(2026, 1, 15) - birthday_cutoff(2026, 1, 20);
    array::from_fn(|offset| {
        let band = offset / 5;
        let band_population = f64::from(JANUARY_THOUSANDS[band]) * 1000.0;
        if band > 0 {
            return f64::from(ADULT_HOLDERS[band - 1]) / band_population;
        }
        // 月報の15～19歳人口を各歳に分ける際も、生年月日を一様と仮定する。
        let age = 15 + offset;
        let days = birthday_cutoff(2026, 1, age) - birthday_cutoff(2026, 1, age + 1);
        let age_population = band_population * f64::from(days) / f64::from(youngest_band_days);
        f64::from(YOUNG_HOLDERS[offset]) / age_population
    })
}

pub struct Demographic {
    pub is_japanese: bool,
    pub birth_date: NaiveDate,
    pub age: u8,
    pub has_license: bool,
}

pub struct PopulationSampler {
    initial: [[u32; 10]; 2],
    remaining: [[u32; 10]; 2],
    total_remaining: u32,
    // 昇順の範囲 [start, end) が各5歳階級の有効な生年月日をちょうど覆う。
    birth_ranges: [std::ops::Range<i32>; 10],
    license_probability: [f64; 50],
    age_counts: [u32; 50],
    holder_counts: [u32; 50],
}

impl PopulationSampler {
    pub fn new(rows: u32) -> Self {
        let national = u64::from(NATIONAL_POPULATION);
        let japanese =
            ((u64::from(rows) * u64::from(JAPANESE_POPULATION) + national / 2) / national) as u32;
        let initial = [
            apportion(japanese, &JAPANESE_THOUSANDS),
            apportion(rows - japanese, &FOREIGN_THOUSANDS),
        ];
        let birth_ranges = array::from_fn(|band| {
            let age = 15 + 5 * band;
            (birthday_cutoff(2026, 5, age + 5) + 1)..(birthday_cutoff(2026, 5, age) + 1)
        });
        Self {
            initial,
            remaining: initial,
            total_remaining: rows,
            birth_ranges,
            license_probability: license_probabilities(),
            age_counts: [0; 50],
            holder_counts: [0; 50],
        }
    }

    /// 残数に比例して区分を選び、全件を引いた時点で指定した人数に一致させる。
    pub fn draw(&mut self, rng: &mut impl Rng) -> Option<Demographic> {
        if self.total_remaining == 0 {
            return None;
        }
        let mut ticket = rng.random_range(0..self.total_remaining);
        let (stratum, remaining) = self
            .remaining
            .iter_mut()
            .flatten()
            .enumerate()
            .find(|(_, count)| {
                if ticket < **count {
                    true
                } else {
                    ticket -= **count;
                    false
                }
            })
            .expect("remaining strata sum to total_remaining");
        *remaining -= 1;
        self.total_remaining -= 1;

        let days = rng.random_range(self.birth_ranges[stratum % 10].clone());
        let birth_date = NaiveDate::from_epoch_days(days).unwrap();
        let age = REFERENCE_DATE.years_since(birth_date).unwrap() as u8;
        let offset = usize::from(age - 15);
        let has_license = rng.random_bool(self.license_probability[offset]);
        self.age_counts[offset] += 1;
        self.holder_counts[offset] += u32::from(has_license);
        Some(Demographic {
            is_japanese: stratum < 10,
            birth_date,
            age,
            has_license,
        })
    }

    pub fn summary(&self) -> impl Serialize {
        let population: Vec<_> = (0..10)
            .map(|band| {
                serde_json::json!({
                    "minimum_age": 15 + 5 * band,
                    "japanese_target": self.initial[0][band],
                    "other_target": self.initial[1][band],
                    "japanese_observed": self.initial[0][band] - self.remaining[0][band],
                    "other_observed": self.initial[1][band] - self.remaining[1][band],
                })
            })
            .collect();
        let license: Vec<_> = (0..50)
            .map(|i| {
                serde_json::json!({
                    "age": i + 15,
                    "holder_probability": self.license_probability[i],
                    "observed_people": self.age_counts[i],
                    "observed_holders": self.holder_counts[i],
                })
            })
            .collect();
        serde_json::json!({
            "reference_date": REFERENCE_DATE.to_string(),
            "population_source": "https://www.stat.go.jp/data/jinsui/pdf/202610.pdf#page=1",
            "population_scope": "2026-05-01の全国15～64歳。総数と日本人相当数を優先し、差を外国人相当とする。各区分に最大剰余法で5歳階級を割り当て、階級内の生年月日を一様に抽選。",
            "population_by_age_band": population,
            "license_holder_source": "https://www.npa.go.jp/publications/statistics/koutsuu/r07main.pdf#page=7",
            "license_denominator_source": "https://www.stat.go.jp/data/jinsui/pdf/202606.pdf#page=1",
            "license_scope": "2025年末の免許保有者数÷2026-01-01の全国人口。15歳は非保有。16～19歳の各歳人口は15～19歳階級内で各生年月日を等確率と仮定して配分。20～64歳は5歳階級内で同率。",
            "licenses_by_age": license,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::{SeedableRng, rngs::StdRng};

    #[test]
    fn quotas_match_each_national_group_and_tiny_populations() {
        let national = PopulationSampler::new(NATIONAL_POPULATION);
        assert_eq!(national.initial[0].iter().sum::<u32>(), 69_873_000);
        assert_eq!(national.initial[1].iter().sum::<u32>(), 3_449_000);
        for total in 0..=21 {
            let sampler = PopulationSampler::new(total);
            assert_eq!(sampler.initial.iter().flatten().sum::<u32>(), total);
        }
    }

    #[test]
    fn birth_range_edges_include_only_the_correct_ages() {
        let sampler = PopulationSampler::new(1);
        for (i, range) in sampler.birth_ranges.iter().enumerate() {
            for (days, expected) in [(range.start, 19 + 5 * i), (range.end - 1, 15 + 5 * i)] {
                let birthday = NaiveDate::from_epoch_days(days).unwrap();
                assert_eq!(REFERENCE_DATE.years_since(birthday), Some(expected as u32));
            }
        }
    }

    #[test]
    fn sampled_dates_licenses_and_strata_agree_with_quotas() {
        let mut sampler = PopulationSampler::new(5000);
        let mut rng = StdRng::seed_from_u64(37);
        let mut counts = [[0_u32; 10]; 2];
        assert_eq!(sampler.license_probability[0], 0.0);
        assert!(
            sampler.license_probability[1..]
                .iter()
                .all(|&p| p > 0.0 && p <= 1.0)
        );
        for _ in 0..5000 {
            let person = sampler.draw(&mut rng).unwrap();
            let age = REFERENCE_DATE.years_since(person.birth_date).unwrap();
            assert_eq!(u32::from(person.age), age);
            assert!(age != 15 || !person.has_license);
            counts[usize::from(!person.is_japanese)][(age as usize - 15) / 5] += 1;
        }
        assert_eq!(counts, sampler.initial);
        assert!(sampler.draw(&mut rng).is_none());
    }
}
