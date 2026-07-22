use std::convert::TryInto;

use alacritty_terminal::{
    Term,
    event::EventListener,
    grid::Dimensions,
    index::{Column, Line, Point},
    term::{Config, RenderableContent},
    vte::ansi::Processor,
};

/// Virtual Terminal for MisTTY that keeps its data in memory.
pub struct VTerm {
    inner: Term<EventAccumulator>,
    processor: Processor,
}

impl VTerm {
    /// Create a new terminal with the given dimensions
    pub fn new(width: usize, height: usize) -> Self {
        let acc = EventAccumulator::new();
        let config = Config::default();
        let inner = Term::new(config, &VTermDimensions::new(width, height), acc);
        let processor = Processor::new();

        Self { inner, processor }
    }

    pub fn inner(&self) -> &Term<EventAccumulator> {
        &self.inner
    }

    pub fn inner_mut(&mut self) -> &mut Term<EventAccumulator> {
        &mut self.inner
    }

    pub fn renderable_content(&self) -> RenderableContent<'_> {
        self.inner.renderable_content()
    }

    /// Parse terminal data and update internal state
    pub fn process_bytes(&mut self, bytes: &[u8]) {
        self.processor.advance(&mut self.inner, bytes);
    }

    /// Return the content of the display as a string.
    pub fn display_string(&self) -> String {
        let offset = self.inner.grid().display_offset().try_into().unwrap();
        let height: i32 = self.inner.screen_lines().try_into().unwrap();
        self.inner.bounds_to_string(
            Point::new(Line(offset), Column(0)),
            Point::new(Line(offset + height - 1), self.inner.last_column()),
        )
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
        // TODO: add scrollback here if necessary
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
pub struct EventAccumulator {}

impl EventAccumulator {
    fn new() -> Self {
        Self {}
    }
}

impl EventListener for EventAccumulator {}
