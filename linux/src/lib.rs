//! Whistt for Omarchy: desktop-wide push-to-talk dictation.
//!
//! Boundaries are split so every one of them can be replaced by a fake in tests:
//! `session` owns the state machine, `audio` owns microphone capture, `transport`
//! owns the provider protocol, and `output` owns text delivery into the focused
//! application. Provider messages never reach the output adapter.

pub mod audio;
pub mod config;
pub mod daemon;
pub mod ipc;
pub mod log;
pub mod openai;
pub mod output;
pub mod session;
pub mod transport;
