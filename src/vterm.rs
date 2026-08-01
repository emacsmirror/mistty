use crate::render;
use alacritty_terminal::{
    Term,
    event::{Event, EventListener},
    grid::Dimensions,
    index::{Column, Line, Point},
    term::{Config, cell::Flags},
    vte::ansi::Processor,
};
use emacs::{Env, IntoLisp, Result, Value};
use std::{cell::RefCell, collections::VecDeque, rc::Rc};

emacs::use_functions! {
    nreverse_func => "nreverse"
}
emacs::use_symbols! {
    pty_write_sym => "pty-write"
}

/// Virtual Terminal for MisTTY that keeps its data in memory.
pub struct VTerm {
    inner: Term<EventAccumulator>,
    processor: Processor,
    events: Rc<RefCell<VecDeque<Event>>>,
    start_with_wrapped_line: bool,
}

impl VTerm {
    /// Create a new terminal with the given dimensions
    pub fn new(width: usize, height: usize) -> Self {
        let events = Rc::new(RefCell::new(VecDeque::new()));
        let acc = EventAccumulator {
            events: Rc::clone(&events),
        };
        let mut config = Config::default();
        config.scrolling_history = 0; // call enable_scrollback to re-enable
        let mut inner = Term::new(config, &VTermDimensions::new(width, height), acc);
        let processor = Processor::new();

        inner.grid_mut().cursor.template.flags |= Flags::DIM;

        Self {
            inner,
            processor,
            events,
            start_with_wrapped_line: false,
        }
    }

    pub fn inner(&self) -> &Term<EventAccumulator> {
        &self.inner
    }

    pub fn inner_mut(&mut self) -> &mut Term<EventAccumulator> {
        &mut self.inner
    }

    pub fn enable_scrollback(&mut self) {
        self.inner.grid_mut().update_history(100000);
    }

    pub fn disable_scrollback(&mut self) {
        self.inner_mut().grid_mut().update_history(0);
    }

    /// Clear history, normally after having written scrollback to the
    /// buffer.
    pub fn clear_history(&mut self) {
        let grid = self.inner_mut().grid_mut();
        if grid.topmost_line() == 0 {
            return;
        }
        let wrapped = grid[Line(-1)][grid.last_column()]
            .flags
            .contains(Flags::WRAPLINE);
        grid.clear_history();

        self.start_with_wrapped_line = wrapped;
    }

    /// Check whether the last line cleared by the previous call to
    /// `clear_history` ended within a line that was wrapped.
    pub fn start_with_wrapped_line(&self) -> bool {
        self.start_with_wrapped_line
    }

    /// Return the first line of scrollback, or the top of the screen.
    ///
    /// The top of the screen is always `Line(0)`. If there are lines
    /// currently in the scrollback buffer of the virtual terminal,
    /// these lines have negative number. Lines on the screen have
    /// positive numbers.
    #[inline]
    pub fn topmost_line(&self) -> Line {
        self.inner.grid().topmost_line()
    }

    /// Return the last line available in the virtual terminal, that
    /// corresponds to the bottom of the screen.
    #[inline]
    pub fn bottommost_line(&self) -> Line {
        self.inner.grid().bottommost_line()
    }

    /// Return the current position of the cursor in the terminal.
    #[inline]
    pub fn cursor_point(&self) -> Point {
        self.inner.grid().cursor.point
    }

    /// Return the current position of the cursor in the terminal.
    #[inline]
    pub fn last_column(&self) -> Column {
        self.inner.grid().last_column()
    }

    /// Return the number of characters between two positions on the string.
    ///
    /// start and end must be valid points within the terminal. End
    /// may be just outside the valid range.
    ///
    /// Newlines count as one character, even newlines added for
    /// wrapping count. Empty columns count as one character.
    pub fn count_chars(&self, start: Point, end: Point) -> usize {
        if start == end {
            return 0;
        }

        // If end points to the beginning of a line, count the newline just before it.
        let (last_line, add_final_nl) = if end.column.0 == 0 {
            (end.line - 1, true)
        } else {
            (end.line, false)
        };
        let grid = self.inner().grid();
        let last_column = grid.last_column();
        let mut buf = String::with_capacity(grid.columns());
        let mut charcount = 0;
        for line in start.line.0..=last_line.0 {
            let line = Line(line);
            let row = &grid[line];
            let start_col = if line == start.line {
                start.column
            } else {
                charcount += 1; // last line newline

                Column(0)
            };
            let end_col = if line == end.line {
                end.column
            } else {
                last_column + 1
            };
            buf.clear();
            for col in start_col.0..end_col.0 {
                render::append_cell_to_string(&row[Column(col)], &mut buf);
            }
            charcount += buf.chars().count();
        }
        if add_final_nl {
            charcount += 1;
        }

        charcount
    }

    /// Return the number of unwrapped line separating `start` from
    /// `end`.
    ///
    /// This counts the number of newlines not marked as line wrap
    /// between `start` and `end`.
    ///
    /// If `end` < `start` a negative number is returned.}
    pub fn count_unwrapped_lines(&self, start: Line, end: Line) -> usize {
        let grid = self.inner.grid();
        let last_col = grid.last_column();
        let mut count = 0;
        for line in start.0..end.0 {
            if !grid[Line(line)][last_col].flags.contains(Flags::WRAPLINE) {
                count += 1;
            }
        }

        count
    }

    /// Parse terminal data and update internal state
    pub fn process_bytes(&mut self, bytes: &[u8]) {
        self.processor.advance(&mut self.inner, bytes);
    }

    /// Handle accumulated events using the given `env`.
    ///
    /// The return value is a list of events that should be handled by
    /// the caller in lisp format.
    pub fn handle_events<'a>(&self, env: &'a Env) -> Result<Value<'a>> {
        let mut events = self.events.borrow_mut();
        let mut result = ().into_lisp(env)?;
        if events.is_empty() {
            return Ok(result);
        }

        while let Some(event) = events.pop_front() {
            let event = match event {
                Event::PtyWrite(data) => Some(env.list((pty_write_sym, data))?),
                _ => None,
            };
            if let Some(lisp_event) = event {
                result = env.cons(lisp_event, result)?;
            }
        }
        result = env.call(nreverse_func, (result,))?;

        Ok(result)
    }

    /// Return the content of the display as the string within range
    /// [start, end).
    ///
    /// start and end must be valid points within the terminal. End
    /// may be just outside the valid range.
    pub fn display_substring(&self, start: Point, end: Point) -> String {
        self.inner.bounds_to_string(start, end)
    }
}

/// Simple dimensions for VTerm.
struct VTermDimensions {
    width: usize,
    height: usize,
}

impl VTermDimensions {
    fn new(width: usize, height: usize) -> Self {
        Self { width, height }
    }
}

impl Dimensions for VTermDimensions {
    fn total_lines(&self) -> usize {
        self.height
    }

    fn screen_lines(&self) -> usize {
        self.height
    }

    fn columns(&self) -> usize {
        self.width
    }
}

/// Accumulate terminal events and return when needed.
pub struct EventAccumulator {
    events: Rc<RefCell<VecDeque<Event>>>,
}

impl EventListener for EventAccumulator {
    fn send_event(&self, event: Event) {
        self.events.borrow_mut().push_back(event);
    }
}
