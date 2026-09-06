"""Test-harness isolation for the vertus server suite.

The fleet hub keeps cross-file state on module and class attributes
(VertusHandler.sessions / registry / store) so that live HTTP handlers,
the serve() wiring, and tests share one path. That sharing is the bug
class that has bitten the harness three times this session:

  1. a stopped RunStore left on VertusHandler.store made later tests'
     /api/prompt 503 silently (Checkpoint 1 of the observability work);
  2. an SSE reader thread from one test holding the hub's write lock
     deadlocked the next (SSE reader test);
  3. wall-clock-tight waits tripping under full-suite load (this fix).

This autouse fixture makes the class-level leak impossible instead of
relying on each file remembering to reset: before every test the shared
attrs return to a pristine state, and any fixture that needs them sets
them fresh (every test file already does exactly that in its own
fixture, so the reset is a no-op for well-behaved files and a crash for
leaky ones — loudly, at the point of leak, not in a later file).
"""

from __future__ import annotations

import pytest

import vertus_server as vs


@pytest.fixture(autouse=True)
def _reset_hub_shared_state():
    """Return the hub's process-global wiring to pristine between tests."""
    vs.VertusHandler.sessions = None
    vs.VertusHandler.registry = None
    vs.VertusHandler.store = None
    yield