use alacritty_terminal::{
    grid::Dimensions,
    term::cell::Flags,
    vte::ansi::{Color, NamedColor},
};
use emacs::{Env, Result, Value, defun};

use crate::vterm::VTerm;

emacs::use_functions! {
    add_face_text_property
    delete_region
    face_foreground
    face_background
    goto_char
    insert
    make_list => "list"
    get_point => "point"
}

emacs::use_symbols! {
    ansi_color_black
    ansi_color_blue
    ansi_color_bold
    ansi_color_bright_black
    ansi_color_bright_blue
    ansi_color_bright_cyan
    ansi_color_bright_green
    ansi_color_bright_magenta
    ansi_color_bright_red
    ansi_color_bright_white
    ansi_color_bright_yellow
    ansi_color_cyan
    ansi_color_green
    ansi_color_inverse
    ansi_color_italic
    ansi_color_magenta
    ansi_color_red
    ansi_color_underlink
    ansi_color_white
    ansi_color_yellow
    default_face => "default"
    cursor_face => "cursor"
    colon_foreground => ":foreground"
    colon_background => ":background"
    colon_italic => ":italic"
    colon_weight => ":weight"
    bold_symbol => "bold"
}

#[derive(PartialEq, Eq, Debug, Clone, Copy)]
enum RenderProperty {
    Fg(Color),
    Bg(Color),
    // Inverse,
    Bold,
    Italic,
    // Underline,
    // Wrapline,
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
    let mut fg = (Color::Named(NamedColor::Foreground), 0);
    let mut bg = (Color::Named(NamedColor::Background), 0);
    let mut italic = None;
    let mut bold = None;
    let mut props = vec![];

    while let Some(cur) = iter.next() {
        let pos = as_string.len() as i32;
        let c = cur.c;
        if c == '\t' {
            // tabs are already stored in the cells as spaces
            as_string.push(' ');
        } else {
            as_string.push(c);
        }
        for c in cur.zerowidth().into_iter().flatten() {
            as_string.push(*c);
        }

        if cur.point.column == screen_columns - 1 {
            as_string.push('\n');
        }

        // track cursor position
        if cur.point == cursor_point {
            cursor_pos = Some(pos);
        }

        // track property changes
        if cur.fg != fg.0 {
            if fg.1 < pos {
                props.push((RenderProperty::Fg(fg.0), fg.1, pos));
            }
            fg = (cur.fg, pos);
        }
        if cur.bg != bg.0 {
            if bg.1 < pos {
                props.push((RenderProperty::Bg(bg.0), bg.1, pos));
            }
            bg = (cur.bg, pos);
        }
        let want_italic = cur.flags.contains(Flags::ITALIC);
        if italic.is_some() != want_italic {
            if let Some(start) = italic {
                props.push((RenderProperty::Italic, start, pos));
                italic = None;
            } else {
                italic = Some(pos);
            }
        }
    }
    props.push((RenderProperty::Fg(fg.0), fg.1, as_string.len() as i32));
    props.push((RenderProperty::Bg(bg.0), bg.1, as_string.len() as i32));
    if let Some(start) = italic {
        props.push((RenderProperty::Italic, start, as_string.len() as i32));
    }
    if let Some(start) = bold {
        props.push((RenderProperty::Bold, start, as_string.len() as i32));
    }

    env.call(delete_region, (start, end))?;
    env.call(goto_char, (start,))?;
    let origin: i32 = env.call(get_point, [])?.into_rust()?;
    env.call(insert, (as_string,))?;
    set_properties(env, props, origin)?;

    if let Some(cursor_pos) = cursor_pos {
        env.call(goto_char, (origin + cursor_pos,))?;
    }

    Ok(())
}

fn set_properties(env: &Env, props: Vec<(RenderProperty, i32, i32)>, origin: i32) -> Result<()> {
    for (prop, start, end) in props {
        match prop {
            RenderProperty::Fg(color) => {
                if let Some(hex) = color_hex(env, color, true)? {
                    env.call(
                        add_face_text_property,
                        (
                            start + origin,
                            end + origin,
                            env.call(make_list, (colon_foreground, hex))?,
                        ),
                    )?;
                }
            }
            RenderProperty::Bg(color) => {
                if let Some(hex) = color_hex(env, color, false)? {
                    env.call(
                        add_face_text_property,
                        (
                            start + origin,
                            end + origin,
                            env.call(make_list, (colon_background, hex))?,
                        ),
                    )?;
                }
            }
            RenderProperty::Italic => {
                env.call(
                    add_face_text_property,
                    (start + origin, end + origin, ansi_color_italic),
                )?;
            }
            RenderProperty::Bold => {
                env.call(
                    add_face_text_property,
                    (start + origin, end + origin, ansi_color_bold),
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn color_hex(env: &Env, color: Color, fg: bool) -> Result<Option<String>> {
    Ok(match color {
        Color::Named(NamedColor::Black | NamedColor::DimBlack) | Color::Indexed(0) => {
            Some(face_to_hex(env, ansi_color_black, fg)?)
        }
        Color::Named(NamedColor::Red | NamedColor::DimRed) | Color::Indexed(1) => {
            Some(face_to_hex(env, ansi_color_red, fg)?)
        }
        Color::Named(NamedColor::Green | NamedColor::DimGreen) | Color::Indexed(2) => {
            Some(face_to_hex(env, ansi_color_green, fg)?)
        }
        Color::Named(NamedColor::Yellow | NamedColor::DimYellow) | Color::Indexed(3) => {
            Some(face_to_hex(env, ansi_color_yellow, fg)?)
        }
        Color::Named(NamedColor::Blue | NamedColor::DimBlue) | Color::Indexed(4) => {
            Some(face_to_hex(env, ansi_color_blue, fg)?)
        }
        Color::Named(NamedColor::Magenta | NamedColor::DimMagenta) | Color::Indexed(5) => {
            Some(face_to_hex(env, ansi_color_magenta, fg)?)
        }
        Color::Named(NamedColor::Cyan | NamedColor::DimCyan) | Color::Indexed(6) => {
            Some(face_to_hex(env, ansi_color_cyan, fg)?)
        }
        Color::Named(NamedColor::White | NamedColor::DimWhite) | Color::Indexed(7) => {
            Some(face_to_hex(env, ansi_color_white, fg)?)
        }
        Color::Named(NamedColor::BrightBlack) | Color::Indexed(8) => {
            Some(face_to_hex(env, ansi_color_black, fg)?)
        }
        Color::Named(NamedColor::BrightRed) | Color::Indexed(9) => {
            Some(face_to_hex(env, ansi_color_red, fg)?)
        }
        Color::Named(NamedColor::BrightGreen) | Color::Indexed(10) => {
            Some(face_to_hex(env, ansi_color_green, fg)?)
        }
        Color::Named(NamedColor::BrightYellow) | Color::Indexed(11) => {
            Some(face_to_hex(env, ansi_color_yellow, fg)?)
        }
        Color::Named(NamedColor::BrightBlue) | Color::Indexed(12) => {
            Some(face_to_hex(env, ansi_color_blue, fg)?)
        }
        Color::Named(NamedColor::BrightMagenta) | Color::Indexed(13) => {
            Some(face_to_hex(env, ansi_color_magenta, fg)?)
        }
        Color::Named(NamedColor::BrightCyan) | Color::Indexed(14) => {
            Some(face_to_hex(env, ansi_color_cyan, fg)?)
        }
        Color::Named(NamedColor::BrightWhite) | Color::Indexed(15) => {
            Some(face_to_hex(env, ansi_color_white, fg)?)
        }
        Color::Named(
            NamedColor::Foreground | NamedColor::BrightForeground | NamedColor::DimForeground,
        ) => {
            if fg {
                None
            } else {
                Some(face_to_hex(env, default_face, false)?)
            }
        }
        Color::Named(NamedColor::Background) => {
            if fg {
                Some(face_to_hex(env, default_face, true)?)
            } else {
                None
            }
        }
        Color::Named(NamedColor::Cursor) => Some(face_to_hex(env, cursor_face, fg)?),
        Color::Spec(rgb) => Some(format!("#{0:02x}{1:02x}{2:02x}", rgb.r, rgb.g, rgb.b)),
        Color::Indexed(code) => {
            if code >= 16 && code <= 231 {
                // [16-231] 6x6x6 color cube
                fn cube6_level(v: u8) -> u8 {
                    if v == 0 { 0 } else { v * 40 + 55 }
                }

                let mut v = code - 16;
                let red = cube6_level(v / 36);
                v = v % 36;
                let green = cube6_level(v / 6);
                v = v % 6;
                let blue = cube6_level(v);

                Some(format!("#{red:02x}{green:02x}{blue:02x}"))
            } else if code >= 232 {
                // [232-255] grayscale
                let gray = (code - 232) * 10 + 8;

                Some(format!("#{gray:02x}{gray:02x}{gray:02x}"))
            } else {
                None
            }
        }
    })
}

fn face_to_hex(env: &Env, face: &emacs::OnceGlobalRef, fg: bool) -> Result<String> {
    let hex: String = env
        .call(
            if fg { face_foreground } else { face_background },
            (face, (), default_face),
        )?
        .into_rust()?;
    Ok(hex)
}
