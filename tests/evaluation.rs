use polars::prelude::*;
use std::{
    collections::BTreeMap,
    ffi::OsStr,
    fs::{self, File},
    path::Path,
    process::Command,
};
use tempfile::tempdir;

fn cli(cwd: &Path, args: impl IntoIterator<Item = impl AsRef<OsStr>>) {
    let result = Command::new(env!("CARGO_BIN_EXE_seminar-synthetic-data"))
        .current_dir(cwd)
        .args(args)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
}

// 集計の各件数と独立に、分母と全件正答のフラグも検算する。
fn assert_summary(
    row: &BTreeMap<String, String>,
    correct: u32,
    incorrect: u32,
    unresolved: u32,
    revealed: u32,
) {
    let targets = correct + incorrect + unresolved;
    for (name, expected) in [
        ("targets", targets),
        ("correct", correct),
        ("incorrect", incorrect),
        ("unresolved", unresolved),
        ("health_revealed", revealed),
    ] {
        assert_eq!(
            row[name].parse::<u32>().unwrap(),
            expected,
            "{name}: {row:?}"
        );
    }
    assert_eq!(
        row["all_correct"].parse::<bool>().unwrap(),
        targets == correct
    );
}

fn score_into(
    round: &Path,
    flags: &[&str],
    output: &Path,
) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut args: Vec<&OsStr> = ["score", "--incidents"]
        .into_iter()
        .map(OsStr::new)
        .collect();
    args.push(round.as_os_str());
    args.extend(flags.iter().map(OsStr::new));
    args.extend([OsStr::new("--output"), output.as_os_str()]);
    cli(round, args);

    let csv = fs::read_to_string(output.join("summary.csv")).unwrap();
    let mut lines = csv.lines();
    let columns = lines.next().unwrap().split(',').collect::<Vec<_>>();
    let mut summaries = BTreeMap::new();
    for line in lines {
        let values = line.split(',').collect::<Vec<_>>();
        assert_eq!(values.len(), columns.len());
        let row: BTreeMap<_, _> = columns
            .iter()
            .zip(values)
            .map(|(&key, value)| (key.to_owned(), value.to_owned()))
            .collect();
        assert!(summaries.insert(row["service"].clone(), row).is_none());
    }
    assert_eq!(
        summaries.keys().map(String::as_str).collect::<Vec<_>>(),
        ["A", "B"]
    );
    summaries
}

fn score(round: &Path, flags: &[&str]) -> BTreeMap<String, BTreeMap<String, String>> {
    let dir = tempdir().unwrap();
    score_into(round, flags, &dir.path().join("result"))
}

#[test]
fn readme_household_and_known_identity_controls() {
    let dir = tempdir().unwrap();
    let root = dir.path();
    cli(
        root,
        [
            "population",
            "--people",
            "3",
            "--seed",
            "1",
            "--output",
            "population",
        ],
    );
    for (round, size, known) in [
        ("one", "1", "100"),
        ("two", "2", "100"),
        ("unknown", "2", "0"),
    ] {
        cli(
            root,
            [
                "incidents",
                "--population",
                "population",
                "--seed",
                "5",
                "--service-size",
                "3",
                "--overlap-percent",
                "100",
                "--mail-reuse-percent",
                "100",
                "--past-incidents",
                "1",
                "--past-size",
                "2",
                "--past-mask",
                "10",
                "--new-mask",
                "10",
                "--known-identity-percent",
                known,
                "--new-size",
                size,
                "--output",
                round,
            ],
        );
    }
    assert_summary(&score(&root.join("one"), &["--mask", "8"])["A"], 0, 0, 1, 0);
    assert_summary(
        &score(&root.join("one"), &["--mask", "10"])["A"],
        1,
        0,
        0,
        1,
    );
    assert_summary(
        &score(&root.join("two"), &["--mask", "10"])["A"],
        1,
        0,
        1,
        1,
    );
    for (round, mask) in [("two", "0"), ("unknown", "10")] {
        for row in score(&root.join(round), &["--mask", mask]).values() {
            assert_summary(row, 0, 0, 2, 0);
        }
    }
}

fn write_parquet(root: &Path, file: &str, mut frame: DataFrame) {
    ParquetWriter::new(File::create(root.join(file)).unwrap())
        .finish(&mut frame)
        .unwrap();
}

#[test]
fn plan_four_rows_and_missing_values() {
    let dir = tempdir().unwrap();
    let root = dir.path();
    for subdir in ["matching", "identity", "scoring"] {
        fs::create_dir(root.join(subdir)).unwrap();
    }

    // ア=10 とイ=20、ウ=30、エ=40。事故ごとに行番号は0から始まる。
    for (incident, names, people, licenses, birthdays) in [
        (
            "past-A-00001",
            vec![1, 2, 3],
            vec![10, 20, 40],
            vec![None, Some(31), Some(65)],
            vec![-100, 530, 900],
        ),
        (
            "past-A-00002",
            vec![2, 1],
            vec![30, 10],
            vec![Some(42), None],
            vec![530, -100],
        ),
    ] {
        let ids: Vec<u32> = (0..names.len() as u32).collect();
        write_parquet(
            root,
            &format!("matching/{incident}.parquet"),
            df!(
                "row_id" => &ids, "surname_code" => &names, "given_name_code" => &names,
                "license_code" => licenses, "birth_date" => birthdays
            )
            .unwrap(),
        );
        write_parquet(
            root,
            &format!("identity/{incident}.parquet"),
            df!(
                "row_id" => &ids, "identity_token" => people
            )
            .unwrap(),
        );
    }
    write_parquet(
        root,
        "scoring/identity-roster.parquet",
        df!(
            "identity_token" => [10,20,30,40], "person_id" => [7,31,42,65]
        )
        .unwrap(),
    );
    for service in ["A", "B"] {
        let first_health = (service == "A").then_some(1);
        write_parquet(root, &format!("matching/new-{service}.parquet"), df!(
            "row_id" => [0,1,2,3], "surname_code" => [1,2,3,4], "given_name_code" => [1,2,3,4],
            "license_code" => [None,Some(101),Some(102),Some(103)], "birth_date" => [-98,2000,3000,4000],
            "health_code" => [first_health,Some(2),Some(1),Some(3)]
        ).unwrap());
        write_parquet(
            root,
            &format!("scoring/new-{service}.parquet"),
            df!(
                "row_id" => [0,1,2,3], "person_id" => [7,42,81,56], "health_truth" => [1,2,1,3]
            )
            .unwrap(),
        );
    }
    let output = root.join("names");
    let by_name = score_into(root, &["--mask", "1"], &output);
    let predictions = ParquetReader::new(File::open(output.join("predictions.parquet")).unwrap())
        .finish()
        .unwrap();
    let row_ids = predictions
        .column("row_id")
        .unwrap()
        .cast(&DataType::Int32)
        .unwrap();
    let candidate_counts = predictions
        .column("candidate_count")
        .unwrap()
        .i64()
        .unwrap();
    let tokens = predictions
        .column("predicted_token")
        .unwrap()
        .cast(&DataType::Int32)
        .unwrap();
    let expected = [(1, Some(10)), (2, None), (1, Some(40)), (0, None)];
    assert_eq!(predictions.height(), 8);
    for (index, id) in row_ids.i32().unwrap().into_no_null_iter().enumerate() {
        assert_eq!(
            (
                candidate_counts.get(index).unwrap(),
                tokens.i32().unwrap().get(index)
            ),
            expected[id as usize],
        );
    }

    assert_summary(&by_name["A"], 1, 1, 2, 1);
    assert_summary(&by_name["B"], 1, 1, 2, 0);
    // 免許のNULL同士と、同一年に生まれた別の日付は、それぞれ完全一致にならない。
    for mask in ["16", "4"] {
        for row in score(root, &["--mask", mask]).values() {
            assert_summary(row, 0, 0, 4, 0);
        }
    }
    let by_year = score(root, &["--mask", "4", "--birth-year"]);
    assert_summary(&by_year["A"], 1, 0, 3, 1);
    assert_summary(&by_year["B"], 1, 0, 3, 0);
}

#[test]
fn service_aliases_with_overlapping_codes_are_scoped_to_each_service() {
    let dir = tempdir().unwrap();
    let root = dir.path();
    for subdir in ["matching", "identity", "scoring"] {
        fs::create_dir(root.join(subdir)).unwrap();
    }

    let rows = [0_u32, 1, 2];
    let people = [7_u32, 31, 42];
    let emails = [100_u32, 101, 102];
    let tokens = [10_u32, 20, 30];
    let health = [1_u32, 2, 1];
    write_parquet(
        root,
        "matching/past-A-00001.parquet",
        df!(
            "row_id" => &rows, "service_nickname" => [1_u32, 2, 3], "mail_code" => &emails
        )
        .unwrap(),
    );
    write_parquet(
        root,
        "identity/past-A-00001.parquet",
        df!(
            "row_id" => &rows, "identity_token" => &tokens
        )
        .unwrap(),
    );
    write_parquet(
        root,
        "scoring/identity-roster.parquet",
        df!(
            "identity_token" => &tokens, "person_id" => &people
        )
        .unwrap(),
    );
    // Bのコード1は偶然同一人物に、コード2・3はAと逆の人物に割り当てた。
    for (service, aliases) in [("A", [1_u32, 2, 3]), ("B", [1, 3, 2])] {
        write_parquet(
            root,
            &format!("matching/new-{service}.parquet"),
            df!(
                "row_id" => &rows, "service_nickname" => &aliases, "mail_code" => &emails,
                "health_code" => &health
            )
            .unwrap(),
        );
        write_parquet(
            root,
            &format!("scoring/new-{service}.parquet"),
            df!(
                "row_id" => &rows, "person_id" => &people, "health_truth" => &health
            )
            .unwrap(),
        );
    }

    for mask in ["1", "3"] {
        let summaries = score(root, &["--mask", mask]);
        assert_summary(&summaries["A"], 3, 0, 0, 3);
        assert_summary(&summaries["B"], 0, 0, 3, 0);
    }
    for summary in score(root, &["--mask", "2"]).values() {
        assert_summary(summary, 3, 0, 0, 3);
    }
}
