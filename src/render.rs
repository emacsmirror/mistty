use std::ops::Deref;

use crate::types::BufferPos;
use crate::vterm::VTerm;
use alacritty_terminal::{
    grid::Dimensions,
    term::cell::{Cell, Flags},
    vte::ansi::{Color, NamedColor},
};
use emacs::{Env, Result, Value, defun};

emacs::use_functions! {
    add_face_text_property
    delete_region
    face_foreground
    face_background
    goto_char
    insert
    list_func => "list"
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
    ansi_color_underline
    ansi_color_white
    ansi_color_yellow
    default_face => "default"
    cursor_face => "cursor"
    foreground_sym => ":foreground"
    background_sym => ":background"
    bold_sym => "bold"
}

#[derive(PartialEq, Eq, Debug, Clone, Copy)]
enum RenderProperty {
    Fg(Color),
    Bg(Color),
    Inverse,
    Bold,
    Italic,
    Underline,
    // Wrapline,
}

/// Render the state of the terminal in a way Emacs understands.
///
/// Rendering is done in the current buffer in the range START to END.
/// The point is left at the cursor position.
#[defun]
pub fn render(env: &Env, term: &VTerm, term_start: Value, term_end: Value) -> Result<()> {
    let screen_columns = term.inner().columns();
    let screen_lines = term.inner().screen_lines();

    let mut cursor_pos = None;
    let mut as_string = String::with_capacity((screen_columns + 1) * screen_lines);
    let mut content = term.inner().renderable_content();
    let cursor_point = content.cursor.point;
    let iter = &mut content.display_iter;

    env.call(goto_char, (term_start,))?;
    let origin = BufferPos::point(env)?;
    let mut tracker = PropertyTracker::new(origin);

    while let Some(cur) = iter.next() {
        let pos = origin + as_string.len();
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
        tracker.track_change(pos, cur.deref())?;
    }
    let end_pos = origin + as_string.len();

    env.call(delete_region, (term_start, term_end))?;
    env.call(insert, (as_string,))?;
    tracker.apply(env, end_pos)?;

    if let Some(cursor_pos) = cursor_pos {
        env.call(goto_char, (cursor_pos,))?;
    }

    Ok(())
}

/// Track cell flags and apply them Emacs-side as text properties.
struct PropertyTracker {
    fg: (Color, BufferPos),
    bg: (Color, BufferPos),
    italic: Option<BufferPos>,
    bold: Option<BufferPos>,
    underline: Option<BufferPos>,
    inverse: Option<BufferPos>,

    buf: Vec<(RenderProperty, BufferPos, BufferPos)>,
}

impl PropertyTracker {
    fn new(origin: BufferPos) -> Self {
        Self {
            fg: (Color::Named(NamedColor::Foreground), origin),
            bg: (Color::Named(NamedColor::Background), origin),
            italic: None,
            bold: None,
            underline: None,
            inverse: None,
            buf: vec![],
        }
    }

    /// Track a flag change at the given buffer position.
    ///
    /// All cells must be passed to track_change in order for the
    /// algorithm to make sense.
    fn track_change(&mut self, pos: BufferPos, cell: &Cell) -> Result<()> {
        if cell.fg != self.fg.0 {
            if self.fg.1 < pos {
                self.buf
                    .push((RenderProperty::Fg(self.fg.0), self.fg.1, pos));
            }
            self.fg = (cell.fg, pos);
        }
        if cell.bg != self.bg.0 {
            if self.bg.1 < pos {
                self.buf
                    .push((RenderProperty::Bg(self.bg.0), self.bg.1, pos));
            }
            self.bg = (cell.bg, pos);
        }
        let want_italic = cell.flags.contains(Flags::ITALIC);
        if self.italic.is_some() != want_italic {
            if let Some(start) = self.italic {
                self.buf.push((RenderProperty::Italic, start, pos));
                self.italic = None;
            } else {
                self.italic = Some(pos);
            }
        }
        let want_bold = cell.flags.contains(Flags::BOLD);
        if self.bold.is_some() != want_bold {
            if let Some(start) = self.bold {
                self.buf.push((RenderProperty::Bold, start, pos));
                self.bold = None;
            } else {
                self.bold = Some(pos);
            }
        }
        let want_underline = cell.flags.contains(Flags::UNDERLINE);
        if self.underline.is_some() != want_underline {
            if let Some(start) = self.underline {
                self.buf.push((RenderProperty::Underline, start, pos));
                self.underline = None;
            } else {
                self.underline = Some(pos);
            }
        }
        let want_inverse = cell.flags.contains(Flags::INVERSE);
        if self.inverse.is_some() != want_inverse {
            if let Some(start) = self.inverse {
                self.buf.push((RenderProperty::Inverse, start, pos));
                self.inverse = None;
            } else {
                self.inverse = Some(pos);
            }
        }

        Ok(())
    }

    /// Set text properties on the current Emacs buffer.
    ///
    /// `end` is the buffer position pointing to the end of the last
    /// cell.
    fn apply(self, env: &Env, end: BufferPos) -> Result<()> {
        for (prop, start, end) in self.at_end(end) {
            match prop {
                RenderProperty::Fg(color) => {
                    if let Some(hex) = to_emacs_color(env, color, true)? {
                        env.call(
                            add_face_text_property,
                            (start, end, env.call(list_func, (foreground_sym, hex))?),
                        )?;
                    }
                }
                RenderProperty::Bg(color) => {
                    if let Some(hex) = to_emacs_color(env, color, false)? {
                        env.call(
                            add_face_text_property,
                            (start, end, env.call(list_func, (background_sym, hex))?),
                        )?;
                    }
                }
                RenderProperty::Italic => {
                    env.call(add_face_text_property, (start, end, ansi_color_italic))?;
                }
                RenderProperty::Bold => {
                    env.call(add_face_text_property, (start, end, ansi_color_bold))?;
                }
                RenderProperty::Underline => {
                    env.call(add_face_text_property, (start, end, ansi_color_underline))?;
                }
                RenderProperty::Inverse => {
                    env.call(add_face_text_property, (start, end, ansi_color_inverse))?;
                }
            }
        }
        Ok(())
    }

    /// Close any currently opened property and return the complete set of properties.
    ///
    /// Normally only called through `apply()`.
    fn at_end(mut self, end: BufferPos) -> Vec<(RenderProperty, BufferPos, BufferPos)> {
        if self.fg.1 < end {
            self.buf
                .push((RenderProperty::Fg(self.fg.0), self.fg.1, end));
        }
        if self.bg.1 < end {
            self.buf
                .push((RenderProperty::Bg(self.bg.0), self.bg.1, end));
        }
        if let Some(start) = self.italic {
            self.buf.push((RenderProperty::Italic, start, end));
        }
        if let Some(start) = self.bold {
            self.buf.push((RenderProperty::Bold, start, end));
        }
        if let Some(start) = self.underline {
            self.buf.push((RenderProperty::Underline, start, end));
        }
        if let Some(start) = self.inverse {
            self.buf.push((RenderProperty::Inverse, start, end));
        }

        let Self { buf, .. } = self;

        buf
    }
}

/// Convert a vte::Color to an emacs color, as a string.
///
/// The color is usually a RGB value starting with #, but it can also
/// be a color name, `unspecified-bg` or `unspecified-fg`.
fn to_emacs_color(env: &Env, color: Color, fg: bool) -> Result<Option<String>> {
    Ok(match color {
        Color::Named(NamedColor::Black | NamedColor::DimBlack) | Color::Indexed(0) => {
            Some(face_color(env, ansi_color_black, fg)?)
        }
        Color::Named(NamedColor::Red | NamedColor::DimRed) | Color::Indexed(1) => {
            Some(face_color(env, ansi_color_red, fg)?)
        }
        Color::Named(NamedColor::Green | NamedColor::DimGreen) | Color::Indexed(2) => {
            Some(face_color(env, ansi_color_green, fg)?)
        }
        Color::Named(NamedColor::Yellow | NamedColor::DimYellow) | Color::Indexed(3) => {
            Some(face_color(env, ansi_color_yellow, fg)?)
        }
        Color::Named(NamedColor::Blue | NamedColor::DimBlue) | Color::Indexed(4) => {
            Some(face_color(env, ansi_color_blue, fg)?)
        }
        Color::Named(NamedColor::Magenta | NamedColor::DimMagenta) | Color::Indexed(5) => {
            Some(face_color(env, ansi_color_magenta, fg)?)
        }
        Color::Named(NamedColor::Cyan | NamedColor::DimCyan) | Color::Indexed(6) => {
            Some(face_color(env, ansi_color_cyan, fg)?)
        }
        Color::Named(NamedColor::White | NamedColor::DimWhite) | Color::Indexed(7) => {
            Some(face_color(env, ansi_color_white, fg)?)
        }
        Color::Named(NamedColor::BrightBlack) | Color::Indexed(8) => {
            Some(face_color(env, ansi_color_black, fg)?)
        }
        Color::Named(NamedColor::BrightRed) | Color::Indexed(9) => {
            Some(face_color(env, ansi_color_red, fg)?)
        }
        Color::Named(NamedColor::BrightGreen) | Color::Indexed(10) => {
            Some(face_color(env, ansi_color_green, fg)?)
        }
        Color::Named(NamedColor::BrightYellow) | Color::Indexed(11) => {
            Some(face_color(env, ansi_color_yellow, fg)?)
        }
        Color::Named(NamedColor::BrightBlue) | Color::Indexed(12) => {
            Some(face_color(env, ansi_color_blue, fg)?)
        }
        Color::Named(NamedColor::BrightMagenta) | Color::Indexed(13) => {
            Some(face_color(env, ansi_color_magenta, fg)?)
        }
        Color::Named(NamedColor::BrightCyan) | Color::Indexed(14) => {
            Some(face_color(env, ansi_color_cyan, fg)?)
        }
        Color::Named(NamedColor::BrightWhite) | Color::Indexed(15) => {
            Some(face_color(env, ansi_color_white, fg)?)
        }
        Color::Named(
            NamedColor::Foreground | NamedColor::BrightForeground | NamedColor::DimForeground,
        ) => {
            if fg {
                // Nothing to set; it's the default
                None
            } else {
                Some(face_color(env, default_face, false)?)
            }
        }
        Color::Named(NamedColor::Background) => {
            if fg {
                Some(face_color(env, default_face, true)?)
            } else {
                // Nothing to set; it's the default
                None
            }
        }
        Color::Named(NamedColor::Cursor) => Some(face_color(env, cursor_face, fg)?),
        Color::Spec(rgb) => Some(format!("#{0:02x}{1:02x}{2:02x}", rgb.r, rgb.g, rgb.b)),
        Color::Indexed(code) => indexed_to_rgb(code),
    })
}

/// Convert an ANSI color code >= 16 to a RGB value.
///
/// Return None if the code is unsupported.
fn indexed_to_rgb(code: u8) -> Option<String> {
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

/// Get the color of a specific Emacs face, to be used in a color spec.
///
/// This is usually, but not always a RGB code starting with #.
fn face_color(env: &Env, face: &emacs::OnceGlobalRef, fg: bool) -> Result<String> {
    let hex: String = env
        .call(
            if fg { face_foreground } else { face_background },
            (face, (), default_face),
        )?
        .into_rust()?;
    Ok(hex)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexed_to_rgb_handpicked() {
        // cornflower blue
        assert_eq!(Some("#5f87ff"), indexed_to_rgb(69).as_deref());

        // dark sea green 2 light
        assert_eq!(Some("#afffaf"), indexed_to_rgb(157).as_deref());

        // grey15
        assert_eq!(Some("#262626"), indexed_to_rgb(235).as_deref());

        // grey85
        assert_eq!(Some("#dadada"), indexed_to_rgb(253).as_deref());
    }

    #[test]
    fn indexed_to_rgb_unsupported() {
        for code in 0..16 {
            assert_eq!(None, indexed_to_rgb(code));
        }
    }

    #[test]
    fn indexed_to_rgb_colors() {
        for red in 0..6 {
            for green in 0..6 {
                for blue in 0..6 {
                    let code = 16 + (red * 36) + (green * 6) + blue;
                    let r = if red != 0 { red * 40 + 55 } else { 0 };
                    let g = if green != 0 { green * 40 + 55 } else { 0 };
                    let b = if blue != 0 { blue * 40 + 55 } else { 0 };
                    assert_eq!(
                        Some(format!("#{r:02x}{g:02x}{b:02x}")),
                        indexed_to_rgb(code),
                        "({red}, {green}, {blue})"
                    );
                }
            }
        }
    }

    #[test]
    fn indexed_to_rgb_grayscale() {
        for gray in 0..24 {
            let level = gray * 10 + 8;
            let code = 232 + gray;
            assert_eq!(
                Some(format!("#{level:02x}{level:02x}{level:02x}")),
                indexed_to_rgb(code),
                "gray: {gray}"
            );
        }
    }
}
