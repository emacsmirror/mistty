mod render;
mod vterm;

use emacs::{Env, IntoLisp, Result, Value, Vector, defun};

use crate::vterm::VTerm;

emacs::plugin_is_GPL_compatible!();

#[emacs::module(
    name = "mistty-mod",
    defun_prefix = "mistty-mod",
    separator = "-",
    mod_in_name = false
)]
fn init(env: &Env) -> Result<Value<'_>> {
    env.provide("mistty-mod")
}

/// Create a virtual terminal wit the given dimensions WIDTH x HEIGHT.
#[defun(user_ptr)]
fn make_vterm(_env: &Env, width: usize, height: usize) -> Result<VTerm> {
    Ok(VTerm::new(width, height))
}

/// Process BYTES coming from a pty and update the virtual terminal.
#[defun]
fn process_bytes(_env: &Env, term: &mut VTerm, bytes: Vector) -> Result<()> {
    let mut v: Vec<u8> = Vec::with_capacity(bytes.len());
    for val in bytes {
        let b: u8 = val.into_rust()?;
        v.push(b);
    }
    term.process_bytes(&v);

    Ok(())
}

/// Return the content of the virtual terminal as a string.
#[defun]
fn display_string<'a>(env: &'a Env, term: &VTerm) -> Result<Value<'a>> {
    let str = term.display_string();

    str.into_lisp(env)
}
