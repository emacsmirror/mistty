use crate::types::BufferPos;
use crate::vterm::VTerm;
use alacritty_terminal::{
    grid::{Dimensions, Indexed},
    index::{Column, Line, Point},
    term::{
        TermDamage,
        cell::{Cell, Flags},
    },
    vte::ansi::{Color, NamedColor},
};
use emacs::{Env, IntoLisp, Result, Value, defun};
use std::{collections::HashMap, ops::Deref};
use strum::IntoEnumIterator;
use strum_macros::EnumIter;

emacs::use_functions! {
    add_face_text_property
    delete_region
    face_foreground
    face_background
    goto_char
    insert
    set_marker
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

/// Cell or text properties.
#[derive(PartialEq, Eq, Debug, Clone, Copy)]
enum RenderProperty {
    /// Foreground color, [Cell::fg].
    Fg(Color),

    /// Background color, [Cell::bg].
    Bg(Color),

    /// Properties that are either on or off, [Cell::flags].
    Toggle(ToggleProperty),
}

/// Boolean properties, that are either on or off [Cell::flags].
#[derive(PartialEq, Eq, Debug, Clone, Copy, Hash, EnumIter)]
enum ToggleProperty {
    Inverse,
    Bold,
    Italic,
    Underline,
    // Wrapline,
}

impl ToggleProperty {
    fn flag(&self) -> Flags {
        match self {
            ToggleProperty::Inverse => Flags::INVERSE,
            ToggleProperty::Bold => Flags::BOLD,
            ToggleProperty::Italic => Flags::ITALIC,
            ToggleProperty::Underline => Flags::UNDERLINE,
        }
    }

    fn is_set(&self, flags: Flags) -> bool {
        flags.intersects(self.flag())
    }
}

/// Render the state of the terminal in a way Emacs understands.
///
/// Rendering is done in the current buffer in the range START to END.
///
/// `cursor_marker` is set to the cursor position.
///
/// The point is not conserved. Wrap this call inside a
/// `save_excursion`.
#[defun]
pub fn render(
    env: &Env,
    term: &mut VTerm,
    term_start: Value,
    term_end: Value,
    cursor_marker: Value,
) -> Result<()> {
    let content = term.inner().renderable_content();
    let mut cursor_pos = None;
    render_region(
        env,
        term,
        content.display_iter,
        term_start,
        term_end,
        &mut cursor_pos,
    )?;

    if let Some(cursor_pos) = cursor_pos {
        env.call(set_marker, (cursor_marker, cursor_pos))?;
    }

    term.inner_mut().reset_damage();

    Ok(())
}

/// Re-render modified parts of the terminal, Emacs-side.
///
/// This call optimizes rendering by only updating the portions of the
/// terminal that have changed since last call to `render` or
/// `render_damage. For this to work, the range START to END must
/// contain the unmodified result of the previous call.
///
/// Rendering is done in the current buffer in the range START to END.
/// The point is left at the cursor position.
///
/// `cursor_marker` is set to the cursor position if that position has
/// changed since last call. If the cursor hasn't moved since last
/// call, the marker might just be left as it is.
///
/// The point is not conserved. Wrap this call inside
/// `save_excursion`.
#[defun]
pub fn render_damaged(
    env: &Env,
    term: &mut VTerm,
    term_start: Value,
    term_end: Value,
    cursor_marker: Value,
) -> Result<()> {
    let mut cursor_pos = None;

    if let TermDamage::Partial(iter) = term.inner_mut().damage() {
        // TODO: check term_end to make sure not to escape the bounds
        // of term_start - term_end even when the buffer content isn't
        // as expected.

        let mut all_damage: Vec<(Line, Column)> = iter
            .filter(|damage| damage.is_damaged())
            .map(|d| (Line(d.line as i32), Column(d.left)))
            .collect();
        all_damage.sort();
        all_damage.dedup_by_key(|(line, _)| line.0);
        // damage is sorted by line, one damage per line, with the
        // column indicating the start of the damage on the line. This
        // is important for the stored cursor position to make sense.

        for (line, left_col) in all_damage {
            env.call(goto_char, (term_start,))?;
            let line_pos = BufferPos::bol(env, line)?;
            env.call(goto_char, (line_pos,))?;
            let next_line_pos = BufferPos::bol(env, Line(1))?;

            let mut damage_start = line_pos;
            let grid_line = &term.inner().grid()[line];
            if left_col > 0 {
                for cell in grid_line[Column(0)..left_col].iter() {
                    damage_start += 1 + cell.zerowidth().map(|chars| chars.len()).unwrap_or(0);
                }
            }

            render_region(
                env,
                term,
                grid_line[left_col..]
                    .iter()
                    .enumerate()
                    .map(|(i, c)| Indexed {
                        point: Point::new(line, left_col + i),
                        cell: c,
                    }),
                damage_start.into_lisp(env)?,
                next_line_pos.into_lisp(env)?,
                &mut cursor_pos,
            )?;
        }
    } else {
        render_region(
            env,
            term,
            term.inner().renderable_content().display_iter,
            term_start,
            term_end,
            &mut cursor_pos,
        )?;
    }

    if let Some(cursor_pos) = cursor_pos {
        env.call(set_marker, (cursor_marker, cursor_pos))?;
    }

    term.inner_mut().reset_damage();

    Ok(())
}

/// Render the display or a subset of the display.
///
/// `iter` should return the cells to render. [`term_start`,
/// `term_end`)] defines the region of the buffer to be replaced with
/// the content of `iter`.
///
/// If `iter` contains the cursor, the function sets `cursor_pos`,
/// otherwise it leaves it alone.
pub fn render_region<'a, I>(
    env: &Env,
    term: &'a VTerm,
    mut iter: I,
    term_start: Value,
    term_end: Value,
    cursor_pos: &mut Option<BufferPos>,
) -> Result<()>
where
    I: Iterator<Item = Indexed<&'a Cell>>,
{
    let screen_columns = term.inner().columns();
    let cursor_point = term.inner().grid().cursor.point;
    env.call(goto_char, (term_start,))?;
    let origin = BufferPos::point(env)?;
    let mut tracker = PropertyTracker::new(origin);

    let mut as_string = string_with_capacity_for(&iter);
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

        // Have we found the cursor? If yes, we now know its position.
        if cur.point == cursor_point {
            *cursor_pos = Some(pos);
        }

        // track property changes
        tracker.track_change(pos, cur.deref())?;
    }
    let end_pos = origin + as_string.len();

    env.call(delete_region, (term_start, term_end))?;
    env.call(insert, (as_string,))?;
    tracker.apply(env, end_pos)?;

    Ok(())
}

/// Build a string with enough capacity for storing the content of
/// `iter`, assuming one character per element.
fn string_with_capacity_for<'a, I>(iter: &I) -> String
where
    I: Iterator<Item = Indexed<&'a Cell>>,
{
    let max = 8192;
    let (low, high) = iter.size_hint();
    if let Some(high) = high
        && high < max
    {
        return String::with_capacity(high);
    }
    if low < max {
        return String::with_capacity(low);
    }

    return String::new();
}

/// Track cell flags and apply them Emacs-side as text properties.
struct PropertyTracker {
    fg: (Color, BufferPos),
    bg: (Color, BufferPos),
    toggles: HashMap<ToggleProperty, BufferPos>,

    buf: Vec<(RenderProperty, BufferPos, BufferPos)>,
}

impl PropertyTracker {
    fn new(origin: BufferPos) -> Self {
        Self {
            fg: (Color::Named(NamedColor::Foreground), origin),
            bg: (Color::Named(NamedColor::Background), origin),
            toggles: HashMap::new(),
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
        for toggle in ToggleProperty::iter() {
            let start = self.toggles.get(&toggle);
            if start.is_some() != toggle.is_set(cell.flags) {
                if let Some(start) = start {
                    self.buf.push((RenderProperty::Toggle(toggle), *start, pos));
                    self.toggles.remove(&toggle);
                } else {
                    self.toggles.insert(toggle, pos);
                }
            }
        }

        Ok(())
    }

    /// Set text properties on the current Emacs buffer.
    ///
    /// `end` is the buffer position pointing to the end of the last
    /// cell.
    fn apply(mut self, env: &Env, end: BufferPos) -> Result<()> {
        // close all ranges
        self.track_change(end, &Cell::default())?;
        assert!(self.toggles.is_empty());
        assert_eq!(self.fg.0, Color::Named(NamedColor::Foreground));
        assert_eq!(self.bg.0, Color::Named(NamedColor::Background));

        let Self { buf, .. } = self;
        for (prop, start, end) in buf {
            match prop {
                RenderProperty::Fg(color) => {
                    if let Some(hex) = to_emacs_color(env, color, true)? {
                        env.call(
                            add_face_text_property,
                            (start, end, env.list((foreground_sym, hex))?),
                        )?;
                    }
                }
                RenderProperty::Bg(color) => {
                    if let Some(hex) = to_emacs_color(env, color, false)? {
                        env.call(
                            add_face_text_property,
                            (start, end, env.list((background_sym, hex))?),
                        )?;
                    }
                }
                RenderProperty::Toggle(ToggleProperty::Italic) => {
                    env.call(add_face_text_property, (start, end, ansi_color_italic))?;
                }
                RenderProperty::Toggle(ToggleProperty::Bold) => {
                    env.call(add_face_text_property, (start, end, ansi_color_bold))?;
                }
                RenderProperty::Toggle(ToggleProperty::Underline) => {
                    env.call(add_face_text_property, (start, end, ansi_color_underline))?;
                }
                RenderProperty::Toggle(ToggleProperty::Inverse) => {
                    env.call(add_face_text_property, (start, end, ansi_color_inverse))?;
                }
            }
        }
        Ok(())
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
