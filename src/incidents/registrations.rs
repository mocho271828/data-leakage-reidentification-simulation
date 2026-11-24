use anyhow::{Result, ensure};
use rand::{Rng, seq::SliceRandom};

pub(super) struct Account {
    pub person_index: usize,
    pub mail: u32,
    pub service_alias: u32,
}

pub(super) struct Registrations {
    pub people: Vec<u32>,
    pub shared_aliases: Vec<u32>,
    pub a: Vec<Account>,
    pub b: Vec<Account>,
}

fn shuffled_codes(size: u32, rng: &mut impl Rng) -> Vec<u32> {
    let mut codes: Vec<_> = (0..size).collect();
    codes.shuffle(rng);
    codes
}

impl Registrations {
    pub fn new(a: Vec<u32>, b: Vec<u32>, reuse: u32, rng: &mut impl Rng) -> Result<Self> {
        let size = u32::try_from(a.len())?;
        let both = size
            .checked_mul(2)
            .ok_or_else(|| anyhow::anyhow!("登録件数がコード範囲を超えています"))?;
        let mut people = a.clone();
        people.extend_from_slice(&b);
        people.sort_unstable();
        people.dedup();

        let shared_aliases = shuffled_codes(u32::try_from(people.len())?, rng);
        // 各コード表を別々に置換し、二つのサービスに同じ個人番号の一部を埋め込まない。
        let mail = shuffled_codes(both, rng);
        let service_alias = shuffled_codes(both, rng);
        let mut first_mail = vec![None; people.len()];
        let accounts = |roster: Vec<u32>, offset: usize| {
            roster
                .into_iter()
                .enumerate()
                .map(|(row, id)| Account {
                    person_index: people.binary_search(&id).expect("登録者は和集合に含まれる"),
                    mail: mail[offset + row],
                    service_alias: service_alias[offset + row],
                })
                .collect::<Vec<_>>()
        };
        let a = accounts(a, 0);
        let mut b = accounts(b, size as usize);
        for account in &a {
            first_mail[account.person_index] = Some(account.mail);
        }
        // Bの登録順が無作為なので、共通登録者の先頭から指定人数を取れば非復元抽出になる。
        let mut reused = 0;
        for account in &mut b {
            if reused == reuse {
                break;
            }
            if let Some(shared) = first_mail[account.person_index] {
                account.mail = shared;
                reused += 1;
            }
        }
        ensure!(reused == reuse, "メール再利用者を指定人数確保できません");
        Ok(Self {
            people,
            shared_aliases,
            a,
            b,
        })
    }
}
