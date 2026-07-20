mod vterm;

use emacs::{Env, IntoLisp, Result, Value, Vector, defun};

use crate::vterm::VTerm;

emacs::plugin_is_GPL_compatible!();

#[emacs::module(name = "mistty-mod", defun_prefix = "mistty-mod", separator = "-")]
fn init(env: &Env) -> Result<Value<'_>> {
    env.message("loaded")
}

#[defun]
fn hello(env: &Env, name: String) -> Result<Value<'_>> {
    format!("Hello {name}").into_lisp(env)
}

#[defun(user_ptr)]
fn make_term(_env: &Env, width: usize, height: usize) -> Result<VTerm> {
    Ok(VTerm::new(width, height))
}

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

#[defun]
fn display_string<'a>(env: &'a Env, term: &VTerm) -> Result<Value<'a>> {
    let str = term.display_string();

    str.into_lisp(env)
}
