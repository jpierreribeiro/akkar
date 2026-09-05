import logging
import threading
import uuid
from contextlib import contextmanager

from celery import Celery

from . import db, storage
from .config import settings
from .model_registry import load_version, predict_loaded

LOGGER = logging.getLogger("akkar.ml.worker")
cfg = settings()
celery = Celery("akkar_ml", broker=cfg.redis_url)
celery.conf.update(
    task_acks_late=True, task_reject_on_worker_lost=True,
    worker_prefetch_multiplier=1, task_serializer="json", accept_content=["json"],
    broker_connection_retry_on_startup=True, broker_connection_timeout=5,
    task_publish_retry=False,
    broker_transport_options={"socket_connect_timeout": 5, "socket_timeout": 5},
    task_soft_time_limit=max(1, cfg.batch_task_time_limit_seconds - 30),
    task_time_limit=cfg.batch_task_time_limit_seconds,
    worker_cancel_long_running_tasks_on_connection_loss=True,
)


class LostLease(Exception):
    pass


@contextmanager
def lease(job_id: str, token: str):
    stop = threading.Event()
    lost = threading.Event()

    def renew():
        while not stop.wait(15):
            try:
                if not db.heartbeat(job_id, token):
                    lost.set()
                    return
            except Exception:
                lost.set()
                return

    thread = threading.Thread(target=renew, daemon=True)
    thread.start()
    try:
        yield lost
    finally:
        stop.set()
        thread.join(timeout=16)


@celery.task(name="akkar_ml.run_batch", bind=True)
def run_batch(self, job_id: str) -> None:  # noqa: ANN001
    # A delivery id can be reused by the broker. Ownership cannot.
    token = str(uuid.uuid4())
    job = db.claim_job(job_id, token)
    if not job:
        return
    context = {"job_id": job_id, "attempt": job["attempts"],
               "request_id": job.get("request_id"), "traceparent": job.get("traceparent")}
    LOGGER.info("batch started %s", context)
    with lease(job_id, token) as lost:
        try:
            rows = storage.read_jsonl(job["input_uri"], job["tenant_id"],
                                      job["input_version_id"], job["input_sha256"])
            loaded = load_version(job["model_name"], job["model_version"],
                                  job["model_digest"], job["model_source"])
            outputs = predict_loaded(loaded, rows)
            if lost.is_set() or not db.heartbeat(job_id, token):
                raise LostLease
            output_uri = (f"s3://{cfg.output_bucket}/{job['tenant_id']}/"
                          f"results/{job_id}/{token}.jsonl")
            storage.write_jsonl(output_uri, job["tenant_id"], outputs)
            if not db.mark_succeeded(job_id, token, output_uri):
                raise LostLease
            LOGGER.info("batch succeeded %s", context)
        except LostLease:
            LOGGER.warning("batch lost lease %s", context)
        except Exception as exc:
            # Do not publish exception messages containing storage URLs/secrets.
            db.mark_failed(job_id, token, type(exc).__name__,
                           retryable=isinstance(exc, (OSError, ConnectionError, TimeoutError)))
            LOGGER.warning("batch failed type=%s context=%s", type(exc).__name__, context)
