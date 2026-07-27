use alacritty_terminal::{
    Term,
    event::{Event, EventListener},
    grid::Dimensions,
    index::{Column, Line, Point},
    term::Config,
    vte::ansi::Processor,
};
use emacs::{Env, IntoLisp, Result, Value};
use std::{cell::RefCell, collections::VecDeque, convert::TryInto, rc::Rc};

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
}

impl VTerm {
    /// Create a new terminal with the given dimensions
    pub fn new(width: usize, height: usize) -> Self {
        let events = Rc::new(RefCell::new(VecDeque::new()));
        let acc = EventAccumulator {
            events: Rc::clone(&events),
        };
        let config = Config::default();
        let inner = Term::new(config, &VTermDimensions::new(width, height), acc);
        let processor = Processor::new();

        Self {
            inner,
            processor,
            events,
        }
    }

    pub fn inner(&self) -> &Term<EventAccumulator> {
        &self.inner
    }

    pub fn inner_mut(&mut self) -> &mut Term<EventAccumulator> {
        &mut self.inner
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
pub struct EventAccumulator {
    events: Rc<RefCell<VecDeque<Event>>>,
}

impl EventListener for EventAccumulator {
    fn send_event(&self, event: Event) {
        self.events.borrow_mut().push_back(event);
    }
}
