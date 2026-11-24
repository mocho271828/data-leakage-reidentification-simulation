use anyhow::{Result, ensure};
use rand::{
    Rng,
    seq::{SliceRandom, index},
};

/// 0..size の行番号を重複なし・無作為な順序で抽選する。
pub(super) fn sample_rows<R: Rng + ?Sized>(size: u32, n: u32, rng: &mut R) -> Result<Vec<u32>> {
    ensure!(
        n <= size,
        "抽出人数 {n} が抽出元の人数 {size} を超えています"
    );
    Ok(index::sample(rng, size as usize, n as usize)
        .into_iter()
        .map(|row| row as u32)
        .collect())
}

/// 人数の等しい2サービスの登録者を、共通登録者数を固定して抽選する。
pub(super) fn rosters<R: Rng + ?Sized>(
    population: u32,
    service_size: u32,
    overlap: u32,
    rng: &mut R,
) -> Result<(Vec<u32>, Vec<u32>)> {
    ensure!(
        overlap <= service_size,
        "共通登録者数 {overlap} がサービス登録者数 {service_size} を超えています"
    );
    let union_size = u64::from(service_size) + u64::from(service_size - overlap);
    ensure!(
        union_size <= u64::from(population),
        "両サービスの実登録者数 {union_size} が人口 {population} を超えています"
    );

    // 和集合を一度抽選し、Aのみ・共通・Bのみの3群に分ける。
    let mut a = sample_rows(population, union_size as u32, rng)?;
    let mut b = a[(service_size - overlap) as usize..].to_vec();
    a.truncate(service_size as usize);
    // 共通登録者が A の末尾や B の先頭に集中しないよう、それぞれ並べ替える。
    a.shuffle(rng);
    b.shuffle(rng);
    Ok((a, b))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use rand::{SeedableRng, rngs::StdRng};

    use super::*;

    #[test]
    fn registration_counts_hold_for_disjoint_partial_and_identical_rosters() -> Result<()> {
        for overlap in [0, 1, 7, 13] {
            let mut rng = StdRng::seed_from_u64(123);
            let (a, b) = rosters(26, 13, overlap, &mut rng)?;
            let a: BTreeSet<_> = a.into_iter().collect();
            let b: BTreeSet<_> = b.into_iter().collect();
            assert_eq!((a.len(), b.len()), (13, 13));
            assert_eq!(a.intersection(&b).count(), overlap as usize);
            assert!(a.union(&b).all(|&id| id < 26));
        }
        Ok(())
    }

    #[test]
    fn infeasible_or_overflowing_counts_return_errors() {
        let mut rng = StdRng::seed_from_u64(123);
        assert!(rosters(10, 8, 5, &mut rng).is_err());
        assert!(rosters(10, 8, 9, &mut rng).is_err());
        assert!(rosters(u32::MAX, u32::MAX, 0, &mut rng).is_err());
        assert!(sample_rows(5, 6, &mut rng).is_err());
    }
}
