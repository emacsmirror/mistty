use emacs::{Env, IntoLisp, Result, Value, defun};

emacs::plugin_is_GPL_compatible!();

#[emacs::module(name = "mistty-mod", defun_prefix = "mistty-mod", separator = "-")]
fn init(env: &Env) -> Result<Value<'_>> {
    env.message("loaded")
}

#[defun]
fn hello(env: &Env, name: String) -> Result<Value<'_>> {
    format!("Hello {name}").into_lisp(env)
}
