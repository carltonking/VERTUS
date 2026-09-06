"""One logging path for the whole hub.

The bug this module exists to prevent: the hub PRINTED, subsystems LOGGED,
and neither saw the other's output, so a dead subsystem was invisible on an
unattended machine. Now every subsystem — the hub's print sites (routed
through hub_print), fleet_routines, fleet_messaging, everything under the
``vertus`` logger namespace — flows through one logger with two sinks:

  - ~/.vertus/logs/vertus.log (override VERTUS_LOG_DIR), rotated at 5MB,
    5 backups — the durable record on an unattended machine
  - stdout — kept for launchd, which captures StandardOutPath

Levels via VERTUS_LOG_LEVEL (default INFO). setup_logging() is idempotent
so tests and repeated serve() calls can never double-register handlers.
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import sys
from pathlib import Path

# Dual import like vertus_server.py: plain for script-dir invocation, package-relative for -m.
try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore

_configured = False


def setup_logging(log_dir: str | Path | None = None,
                  level: str | None = None) -> logging.Logger:
    """Configure the ``vertus`` logger once; safe to call repeatedly.

    ``log_dir``/``level`` default to VERTUS_LOG_DIR / VERTUS_LOG_LEVEL env
    vars, then the module defaults. The file handler rotates (5MB x 5); the
    stream handler writes to stdout for launchd. Subsystem loggers are
    children of ``vertus`` and inherit both handlers.
    """
    global _configured
    root = logging.getLogger("vertus")
    if _configured:
        return root
    root.setLevel((level or os.environ.get("VERTUS_LOG_LEVEL", "INFO")).upper())
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    # Log dir resolution lives in vertus_paths.logs_dir (VERTUS_LOG_DIR →
    # VERTUS_ROOT → ~/.vertus/logs), call-time so hermetic hubs log to temp.
    directory = Path(log_dir or vertus_paths.logs_dir())
    try:
        directory.mkdir(parents=True, exist_ok=True)
        file_handler = logging.handlers.RotatingFileHandler(
            directory / "vertus.log",
            maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8",
        )
        file_handler.setFormatter(fmt)
        root.addHandler(file_handler)
    except OSError as exc:
        # A hub that cannot write its log dir should still log to stdout.
        logging.getLogger("vertus").error(
            "log file unavailable (%s); falling back to stdout only", exc
        )
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(fmt)
    root.addHandler(stream)
    root.propagate = False
    _configured = True
    return root


def get_logger(name: str) -> logging.Logger:
    """A subsystem logger under the shared ``vertus`` namespace."""
    return logging.getLogger(f"vertus.{name}")


def hub_print(*args, **kwargs) -> None:
    """Replacement for the hub's module-level ``print``.

    Every existing ``print(f"[vertus] ...")`` site routes through here, so
    boot, escalation, driver-sweep, and retention lines land in the SAME
    file as the subsystem loggers — one log, one story. ``flush=`` and other
    print kwargs are accepted and ignored (logging flushes per emit).
    """
    setup_logging()
    logging.getLogger("vertus").info(" ".join(str(a) for a in args))