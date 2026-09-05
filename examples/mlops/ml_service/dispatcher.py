"""Run separately: python -m ml_service.dispatcher. No broker needed by API."""
import logging
import signal
import threading

from . import db
from .tasks import run_batch

LOGGER = logging.getLogger("akkar.ml.dispatcher")


def tick() -> int:
    db.reconcile()
    sent = 0
    while sent < 100 and db.dispatch_one(run_batch.delay):
        sent += 1
    return sent


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    while not stop.is_set():
        try:
            sent = tick()
            if sent:
                LOGGER.info("outbox dispatched=%d", sent)
        except Exception as exc:
            LOGGER.warning("outbox unavailable type=%s", type(exc).__name__)
        stop.wait(1)


if __name__ == "__main__":
    main()
