/// 合計が指定人数に一致するよう、正の合計を持つ重みを最大剰余法で整数配分する。
/// 同じ剰余では入力の先頭側（若い階級・上位の姓）を優先する。
pub(crate) fn apportion<const N: usize>(total: u32, weights: &[u32; N]) -> [u32; N] {
    let denominator: u64 = weights.iter().copied().map(u64::from).sum();
    let products = weights.map(|weight| u64::from(weight) * u64::from(total));
    let mut counts = products.map(|product| (product / denominator) as u32);
    let extra = total - counts.iter().sum::<u32>();
    let mut indices: [usize; N] = std::array::from_fn(|i| i);
    indices.sort_by_key(|&i| std::cmp::Reverse(products[i] % denominator));
    for &i in &indices[..extra as usize] {
        counts[i] += 1;
    }
    counts
}
