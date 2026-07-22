use alacritty_terminal::grid::Dimensions;
use emacs::{Env, Result, Value, defun};

use crate::vterm::VTerm;

emacs::use_functions! {
    delete_region => "delete-region"
    goto_char => "goto-char"
    insert => "insert"
    get_point => "point"

    message => "message"
}

/// Render the state of the terminal in a way Emacs understands.
///
/// Rendering is done in the current buffer in the range START to END.
/// The point is left at the cursor position.
#[defun]
pub fn render(env: &Env, term: &VTerm, start: Value, end: Value) -> Result<()> {
    let screen_columns = term.inner().columns();
    let screen_lines = term.inner().screen_lines();

    let mut cursor_pos = None;
    let mut as_string = String::with_capacity((screen_columns + 1) * screen_lines);
    let mut content = term.inner().renderable_content();
    let cursor_point = content.cursor.point;
    let iter = &mut content.display_iter;
    while let Some(cell) = iter.next() {
        let pos = as_string.len() as i32;
        let c = cell.c;
        if c == '\t' {
            // tabs are already stored in the cells as spaces
            as_string.push(' ');
        } else {
            as_string.push(c);
        }
        for c in cell.zerowidth().into_iter().flatten() {
            as_string.push(*c);
        }

        let point = iter.point();
        if point.column == screen_columns - 1 {
            as_string.push('\n');
        }
        if point == cursor_point {
            cursor_pos = Some(pos);
        }
    }
    env.call(delete_region, (start, end))?;
    env.call(goto_char, (start,))?;
    let origin: i32 = env.call(get_point, [])?.into_rust()?;
    env.call(insert, (as_string,))?;

    if let Some(cursor_pos) = cursor_pos {
        env.call(goto_char, (origin + cursor_pos,))?;
    }

    Ok(())
}
