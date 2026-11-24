mod apportion;
mod demography;
mod evaluation;
mod households;
mod incidents;
mod names;
mod population;
mod projection;

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    version,
    about = "実験用の架空人口・サービス登録・漏えい記録を生成する"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// 採点用の人物と世帯を生成する
    Population {
        #[command(flatten)]
        args: population::PopulationArgs,
        /// 新しく作る出力ディレクトリ
        #[arg(long)]
        output: PathBuf,
    },
    /// 同一反復の新規漏えいから基本条件の列だけを取り出す
    Project {
        #[command(flatten)]
        args: projection::ProjectionArgs,
        /// 新しく作る出力ディレクトリ
        #[arg(long)]
        output: PathBuf,
    },
    /// 1反復の新規事故について過去の既知人物と照合し、サービス別に採点する
    Score {
        #[command(flatten)]
        args: evaluation::ScoreArgs,
        /// 新しく作る出力ディレクトリ
        #[arg(long)]
        output: PathBuf,
    },
    /// 既存の人口から1反復分の登録・漏えい記録を生成する
    Incidents {
        #[command(flatten)]
        args: incidents::IncidentArgs,
        /// 新しく作る出力ディレクトリ
        #[arg(long)]
        output: PathBuf,
    },
}

fn write_dataset(output: &Path, generate: impl FnOnce(&Path) -> Result<()>) -> Result<()> {
    let parent = output
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    ensure!(
        output.file_name().is_some(),
        "出力には新しいディレクトリ名を指定してください"
    );
    fs::create_dir_all(parent)?;
    ensure!(
        fs::symlink_metadata(output).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
        "出力先はすでに存在するか参照できません: {}",
        output.display()
    );
    let staging = tempfile::Builder::new()
        .prefix(".generating-")
        .tempdir_in(parent)?;
    generate(staging.path())?;
    // 完成したディレクトリだけを公開する。同一出力先への並行実行でも既存結果を保護する。
    fs::create_dir(output)
        .with_context(|| format!("出力先を確保できません: {}", output.display()))?;
    if let Err(error) = fs::rename(staging.path(), output) {
        let _ = fs::remove_dir(output);
        return Err(error).context("完成したデータを出力先に移動できません");
    }
    eprintln!("生成完了 {}", output.display());
    Ok(())
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Population { args, output } => {
            write_dataset(&output, |dir| population::generate(&args, dir))
        }
        Command::Project { args, output } => {
            write_dataset(&output, |dir| projection::generate(&args, dir))
        }
        Command::Score { args, output } => {
            write_dataset(&output, |dir| evaluation::score(&args, dir))
        }
        Command::Incidents { args, output } => {
            write_dataset(&output, |dir| incidents::generate(&args, dir))
        }
    }
}
