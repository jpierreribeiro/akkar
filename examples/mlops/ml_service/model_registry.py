import hashlib
import hmac
import threading
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

import mlflow
import mlflow.artifacts
import mlflow.sklearn
import pandas as pd
from mlflow import MlflowClient
from mlflow.models import Model

from .config import settings


@dataclass(frozen=True)
class LoadedModel:
    name: str
    version: str
    digest: str
    predictor: Any


_models: OrderedDict[tuple[str, str, str], LoadedModel] = OrderedDict()
_lock = threading.Lock()


def artifact_digest(path: str | Path) -> str:
    root = Path(path)
    digest = hashlib.sha256()
    for file in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = file.relative_to(root).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        with file.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def verify_safe_sklearn_artifact(path: str | Path) -> None:
    flavors = Model.load(str(Path(path) / "MLmodel")).flavors
    if set(flavors) - {"sklearn", "python_function"}:
        raise RuntimeError("unexpected model flavor")
    sklearn = flavors.get("sklearn")
    pyfunc = flavors.get("python_function")
    if not sklearn or sklearn.get("serialization_format") != "skops":
        raise RuntimeError("only sklearn models serialized with skops are accepted")
    if sklearn.get("code") or (pyfunc and pyfunc.get("code")):
        raise RuntimeError("model artifacts containing executable code are refused")
    if pyfunc and pyfunc.get("loader_module") != "mlflow.sklearn":
        raise RuntimeError("unexpected Python flavor loader")


def resolve(name: str, alias: str) -> dict[str, str]:
    cfg = settings()
    mlflow.set_tracking_uri(cfg.mlflow_tracking_uri)
    client = MlflowClient()
    version = client.get_model_version_by_alias(name, alias)
    expected_digest = version.tags.get("artifact_digest")
    if cfg.require_model_digest and not expected_digest:
        raise RuntimeError(f"model {name}/{version.version} has no artifact_digest tag")
    if not expected_digest:
        raise RuntimeError("immutable jobs require a model digest")
    return {"model_version": str(version.version), "model_digest": expected_digest,
            "model_source": version.source}


def load(name: str, alias: str) -> LoadedModel:
    return load_version(name, **resolve(name, alias))


def load_version(name: str, model_version: str, model_digest: str, model_source: str) -> LoadedModel:
    mlflow.set_tracking_uri(settings().mlflow_tracking_uri)
    expected_digest = model_digest

    key = (name, model_version, model_digest)
    with _lock:
        found = _models.get(key)
        if found:
            _models.move_to_end(key)
            return found
        # sklearn loads into memory; downloaded files need not accumulate on disk.
        with TemporaryDirectory(prefix="akkar-model-") as directory:
            path = mlflow.artifacts.download_artifacts(
                artifact_uri=model_source, dst_path=directory
            )
            verify_safe_sklearn_artifact(path)
            actual_digest = artifact_digest(path)
            if expected_digest and not hmac.compare_digest(actual_digest, expected_digest):
                raise RuntimeError(f"artifact digest mismatch for model {name}/{model_version}")
            predictor = mlflow.sklearn.load_model(path)
        loaded = LoadedModel(name, model_version, actual_digest, predictor)
        _models[key] = loaded
        while len(_models) > 2:
            _models.popitem(last=False)
        return loaded


def predict(name: str, alias: str, rows: list[dict[str, Any]]) -> tuple[list[Any], LoadedModel]:
    loaded = load(name, alias)
    return predict_loaded(loaded, rows), loaded


def predict_loaded(loaded: LoadedModel, rows: list[dict[str, Any]]) -> list[Any]:
    frame = pd.DataFrame.from_records(rows)
    expected = getattr(loaded.predictor, "feature_names_in_", None)
    if expected is not None:
        expected_names = [str(value) for value in expected]
        missing = sorted(set(expected_names) - set(frame.columns))
        extra = sorted(set(frame.columns) - set(expected_names))
        if missing or extra:
            raise ValueError(f"model input columns differ: missing={missing}, extra={extra}")
        # JSON object order is not semantic. Scikit-learn dataframes are, so
        # restore the training order recorded in the immutable model.
        frame = frame.loc[:, expected_names]
    result = loaded.predictor.predict(frame)
    if hasattr(result, "tolist"):
        result = result.tolist()
    elif hasattr(result, "to_dict"):
        result = result.to_dict(orient="records")
    if not isinstance(result, list):
        result = [result]
    return result
