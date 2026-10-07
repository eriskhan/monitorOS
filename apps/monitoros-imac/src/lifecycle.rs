//! Policy only: the runtime executes actions and acknowledges completed work.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Link {
    pub index: i32,
    /// Both administrative UP and carrier (LOWER_UP) are required.
    pub up: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkerAction {
    Start,
    Stop,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum Worker {
    #[default]
    Absent,
    Running,
    StopRequested,
}

#[derive(Default)]
pub struct Lifecycle {
    link: Option<Link>,
    configured: bool,
    worker: Worker,
    shutting_down: bool,
}

impl Lifecycle {
    pub fn observe_link(&mut self, link: Option<Link>) -> bool {
        if self.link == link {
            return false;
        }

        // A loss of carrier, deletion, or new interface generation invalidates
        // the accepted TCP session. An UP arriving during cleanup cannot cancel
        // this request: the old child must be reaped before any new one starts.
        if let Some(previous) = self.link {
            if link.is_none_or(|next| next.index != previous.index || (previous.up && !next.up)) {
                self.request_stop();
            }
        }
        self.link = link;
        self.configured = false;
        true
    }

    pub fn needs_configuration(&self) -> bool {
        !self.shutting_down && self.link.is_some() && !self.configured
    }

    pub fn configured(&mut self) {
        self.configured = true;
    }

    pub fn worker_action(&self) -> Option<WorkerAction> {
        match self.worker {
            Worker::StopRequested => Some(WorkerAction::Stop),
            Worker::Absent if !self.shutting_down => Some(WorkerAction::Start),
            _ => None,
        }
    }

    pub fn worker_started(&mut self) {
        assert_eq!(self.worker, Worker::Absent);
        self.worker = Worker::Running;
    }

    /// Called only after wait/try_wait has reaped the owned child.
    pub fn worker_reaped(&mut self) {
        self.worker = Worker::Absent;
    }

    pub fn shutdown(&mut self) {
        self.shutting_down = true;
        self.request_stop();
    }

    pub fn finished(&self) -> bool {
        self.shutting_down && self.worker == Worker::Absent
    }

    fn request_stop(&mut self) {
        if self.worker == Worker::Running {
            self.worker = Worker::StopRequested;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const UP: Option<Link> = Some(Link { index: 7, up: true });
    const DOWN: Option<Link> = Some(Link {
        index: 7,
        up: false,
    });

    fn running() -> Lifecycle {
        let mut state = Lifecycle::default();
        state.observe_link(UP);
        state.configured();
        state.worker_started();
        state
    }

    #[test]
    fn disappearing_or_down_link_requests_graceful_stop() {
        for link in [None, DOWN] {
            let mut state = running();
            state.observe_link(link);
            assert_eq!(state.worker_action(), Some(WorkerAction::Stop));
        }
    }

    #[test]
    fn replug_cannot_bypass_reaping_the_old_session() {
        let mut state = running();
        state.observe_link(None);
        state.observe_link(UP);
        assert!(state.needs_configuration());
        assert_eq!(state.worker_action(), Some(WorkerAction::Stop));
        state.worker_reaped();
        state.configured();
        assert_eq!(state.worker_action(), Some(WorkerAction::Start));
        state.worker_started();
        assert_eq!(state.worker_action(), None);
        assert!(!state.needs_configuration());
    }

    #[test]
    fn repeated_events_never_create_multiple_workers() {
        let mut state = running();
        for link in [DOWN, DOWN, UP, UP, DOWN, UP] {
            state.observe_link(link);
            assert_eq!(state.worker_action(), Some(WorkerAction::Stop));
        }
        state.worker_reaped();
        state.worker_started();
        for _ in 0..3 {
            assert!(!state.observe_link(UP));
            assert_eq!(state.worker_action(), None);
        }
    }

    #[test]
    fn worker_exit_with_link_up_restarts_without_reconfiguring() {
        let mut state = running();
        state.worker_reaped();
        assert_eq!(state.worker_action(), Some(WorkerAction::Start));
        assert!(!state.needs_configuration());
    }

    #[test]
    fn shutdown_stops_child_and_never_restarts_it() {
        let mut state = running();
        state.shutdown();
        assert_eq!(state.worker_action(), Some(WorkerAction::Stop));
        state.observe_link(None);
        state.observe_link(UP);
        assert!(!state.needs_configuration());
        state.worker_reaped();
        assert_eq!(state.worker_action(), None);
        assert!(state.finished());
    }

    #[test]
    fn boot_without_link_can_start_a_listener() {
        let mut state = Lifecycle::default();
        assert!(!state.needs_configuration());
        assert_eq!(state.worker_action(), Some(WorkerAction::Start));
        state.worker_started();
        state.observe_link(DOWN);
        assert!(state.needs_configuration());
        assert_eq!(state.worker_action(), None);
    }

    #[test]
    fn changed_interface_index_invalidates_session_even_without_delete() {
        let mut state = running();
        state.observe_link(Some(Link { index: 9, up: true }));
        assert!(state.needs_configuration());
        assert_eq!(state.worker_action(), Some(WorkerAction::Stop));
    }
}
