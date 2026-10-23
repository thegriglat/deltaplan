//! Picard iteration of the 3D steady Boussinesq air model (AM-01) in Rust.
//!
//! Port of the reference `tools/research/air3d/air.py` (one outer iteration, residual
//! check, stopping criterion, finalize) on the R1 flat halo layout, `f32` storage and
//! arithmetic like the GPU in the game. Every function is pure: inputs in, explicit
//! `&mut` output buffers out; threads come from an explicit `rayon::ThreadPool`.

pub mod blocks;
pub mod case;
pub mod kernels;
pub mod lines;
pub mod mg;
pub mod report;
pub mod solver;
pub mod util;
