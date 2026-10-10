//! CLI `osmtiles` (O5). `pack` и `finalize` — в OT-2; здесь `dump`, `stats`, `cover`, `manifest`.

use clap::{Parser, Subcommand};
use osmtiles::{codec, cover, manifest, pb, stats};
use prost::Message;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "osmtiles", about = "Тайлы OSM 20 км: упаковщик и инструменты")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Фрагменты O4 из выгрузки региона (OT-2).
    Pack {
        #[arg(long)] input: PathBuf,
        #[arg(long)] region: String,
        #[arg(long)] poly: Option<PathBuf>,
        #[arg(long)] frag_dir: PathBuf,
        #[arg(long)] tmp: Option<PathBuf>,
        #[arg(long)] threads: Option<usize>,
        #[arg(long)] report: Option<PathBuf>,
    },
    /// Склейка тайлов из фрагментов (OT-2).
    Finalize {
        #[arg(long)] frag_dir: PathBuf,
        #[arg(long)] out: PathBuf,
        #[arg(long)] list: PathBuf,
        #[arg(long)] threads: Option<usize>,
        #[arg(long)] report: Option<PathBuf>,
    },
    /// Тайлы, пересекающие полигон `.poly`: строки `j i`.
    Cover {
        #[arg(long)] poly: PathBuf,
    },
    /// Сводка O6 (JSON).
    Stats {
        #[arg(long)] tiles: PathBuf,
        #[arg(long)] zstd_per_stream: bool,
        /// Файл со строками `j i`.
        #[arg(long)] only: Option<PathBuf>,
        #[arg(long)] threads: Option<usize>,
    },
    /// Разбор файла O2 (или манифеста `.pb`) в JSON.
    Dump { file: PathBuf },
    /// Манифест O7.
    Manifest {
        #[arg(long)] tiles: PathBuf,
        #[arg(long)] sources: PathBuf,
        #[arg(long)] out: PathBuf,
        /// Метка времени (по умолчанию — сейчас); для воспроизводимых тестов.
        #[arg(long)] created_unix: Option<i64>,
    },
    /// Пишет образцы `sample_v1.dpt` и `sample_frag_v1.dpt` в каталог.
    #[command(hide = true)]
    Sample { dir: PathBuf },
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn set_threads(n: Option<usize>) {
    if let Some(n) = n {
        let _ = rayon::ThreadPoolBuilder::new().num_threads(n).build_global();
    }
}

fn run(cmd: Cmd) -> Result<(), String> {
    match cmd {
        Cmd::Pack { .. } | Cmd::Finalize { .. } => Err("pack/finalize: не реализовано (задача OT-2)".into()),
        Cmd::Cover { poly } => {
            let text = std::fs::read_to_string(&poly).map_err(|e| format!("{}: {e}", poly.display()))?;
            let tiles = cover::cover(&cover::parse_poly(&text)?);
            let mut out = String::new();
            for (j, i) in tiles {
                out.push_str(&format!("{j} {i}\n"));
            }
            print!("{out}");
            Ok(())
        }
        Cmd::Stats { tiles, zstd_per_stream, only, threads } => {
            let only = match only {
                Some(p) => {
                    let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
                    let mut s = BTreeSet::new();
                    for l in text.lines().filter(|l| !l.trim().is_empty()) {
                        let mut it = l.split_whitespace();
                        let j = it.next().and_then(|x| x.parse().ok()).ok_or_else(|| format!("--only: «{l}»"))?;
                        let i = it.next().and_then(|x| x.parse().ok()).ok_or_else(|| format!("--only: «{l}»"))?;
                        s.insert((j, i));
                    }
                    Some(s)
                }
                None => None,
            };
            let v = stats::stats_json(&tiles, zstd_per_stream, only, threads)?;
            println!("{}", serde_json::to_string_pretty(&v).unwrap());
            Ok(())
        }
        Cmd::Dump { file } => {
            let data = std::fs::read(&file).map_err(|e| format!("{}: {e}", file.display()))?;
            let v = if data.starts_with(codec::MAGIC) {
                codec::dump_json(&data)?
            } else {
                let m = pb::TileManifest::decode(data.as_slice()).map_err(|e| format!("не тайл и не манифест: {e}"))?;
                manifest::manifest_json(&m)
            };
            println!("{}", serde_json::to_string_pretty(&v).unwrap());
            Ok(())
        }
        Cmd::Manifest { tiles, sources, out, created_unix } => {
            let text = std::fs::read_to_string(&sources).map_err(|e| format!("{}: {e}", sources.display()))?;
            let src = manifest::parse_sources(&serde_json::from_str(&text).map_err(|e| e.to_string())?)?;
            let created = created_unix.unwrap_or_else(|| {
                std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
            });
            let m = manifest::build_manifest(&tiles, src, created)?;
            write_atomic(&out, &m.encode_to_vec())?;
            eprintln!("манифест: {} тайлов, {} Б", m.tiles.len(), m.total_bytes);
            Ok(())
        }
        Cmd::Sample { dir } => {
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            write_atomic(&dir.join("sample_v1.dpt"), &codec::encode_tile(&osmtiles::sample::sample_tile(false), None)?)?;
            write_atomic(&dir.join("sample_frag_v1.dpt"), &codec::encode_tile(&osmtiles::sample::sample_tile(true), None)?)
        }
    }
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) => {
            let _ = e.print();
            return ExitCode::from(if e.use_stderr() { 2 } else { 0 });
        }
    };
    match &cli.cmd {
        Cmd::Stats { threads, .. } | Cmd::Pack { threads, .. } | Cmd::Finalize { threads, .. } => set_threads(*threads),
        _ => {}
    }
    match run(cli.cmd) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("osmtiles: {e}");
            ExitCode::from(1)
        }
    }
}
