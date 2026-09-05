from contextlib import contextmanager
from threading import Event
from types import SimpleNamespace

from ml_service import tasks


def setup(monkeypatch, *, wins=True, upload_fails=False):
    events = []
    job = dict(tenant_id="acme", input_uri="s3://ml-batch/acme/in", input_version_id="old",
               input_sha256="a" * 64, model_name="demo", model_version="7",
               model_digest="sha256:abc", model_source="s3://models/fixed", attempts=2)
    monkeypatch.setattr(tasks.uuid, "uuid4", lambda: "fresh-attempt-token")
    monkeypatch.setattr(tasks.db, "claim_job", lambda *args: events.append(("claim", args)) or job)
    monkeypatch.setattr(tasks.db, "heartbeat", lambda *_: True)
    monkeypatch.setattr(tasks.storage, "read_jsonl", lambda *args: events.append(("read", args)) or [{"x": 1}])
    monkeypatch.setattr(tasks, "load_version", lambda *args: events.append(("model", args)) or object())
    monkeypatch.setattr(tasks, "predict_loaded", lambda *_: [1])
    def write(*args):
        events.append(("upload", args))
        if upload_fails:
            raise OSError("private storage connection data")
    monkeypatch.setattr(tasks.storage, "write_jsonl", write)
    monkeypatch.setattr(tasks.db, "mark_succeeded", lambda *args: events.append(("finish", args)) or wins)
    monkeypatch.setattr(tasks.db, "mark_failed", lambda *args, **kw: events.append(("fail", args, kw)))
    @contextmanager
    def lease(*_):
        yield Event()
    monkeypatch.setattr(tasks, "lease", lease)
    return events


def test_worker_uses_fixed_inputs_model_and_attempt_scoped_output(monkeypatch):
    events = setup(monkeypatch)
    tasks.run_batch.run("job-1")
    assert events[0] == ("claim", ("job-1", "fresh-attempt-token"))
    assert events[1][1][2:] == ("old", "a" * 64)
    assert events[2][1] == ("demo", "7", "sha256:abc", "s3://models/fixed")
    assert events[3][1][0].endswith("/acme/results/job-1/fresh-attempt-token.jsonl")
    assert events[4][1] == ("job-1", "fresh-attempt-token", events[3][1][0])


def test_losing_worker_does_not_mark_the_new_owner_failed(monkeypatch):
    events = setup(monkeypatch, wins=False)
    tasks.run_batch.run("job-1")
    assert not any(event[0] == "fail" for event in events)


def test_failed_upload_never_publishes_uri_and_redacts_error(monkeypatch):
    events = setup(monkeypatch, upload_fails=True)
    tasks.run_batch.run("job-1")
    assert not any(event[0] == "finish" for event in events)
    assert events[-1] == ("fail", ("job-1", "fresh-attempt-token", "OSError"), {"retryable": True})
