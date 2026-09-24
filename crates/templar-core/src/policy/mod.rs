//! Miniscript Policy Engine.
//!
//! Provides policy fragments, predefined templates, a compiler that produces
//! BDK-compatible `wsh(...)` descriptors, and a validator that enumerates
//! all spending paths.

pub mod engine;
pub mod fragments;
pub mod templates;
pub mod validator;
