from pathlib import Path

import pytest

from ml_service.model_registry import (
    LoadedModel,
    artifact_digest,
    predict,
    verify_safe_sklearn_artifact,
)
import ml_service.model_registry as registry


def write_mlmodel(root: Path, serialization: str = "skops", code: str | None = None) -> None:
    code_line = f"    code: {code}\n" if code else ""
    (root / "MLmodel").write_text(
        "flavors:\n"
        "  python_function:\n"
        "    loader_module: mlflow.sklearn\n"
        f"{code_line}"
        "  sklearn:\n"
        f"    serialization_format: {serialization}\n"
    )


def test_accepts_skops_without_packaged_code(tmp_path):
    write_mlmodel(tmp_path)
    verify_safe_sklearn_artifact(tmp_path)


@pytest.mark.parametrize("serialization", ["pickle", "cloudpickle"])
def test_refuses_unsafe_serialization(tmp_path, serialization):
    write_mlmodel(tmp_path, serialization=serialization)
    with pytest.raises(RuntimeError, match="skops"):
        verify_safe_sklearn_artifact(tmp_path)


def test_refuses_packaged_python_code(tmp_path):
    write_mlmodel(tmp_path, code="code")
    with pytest.raises(RuntimeError, match="executable code"):
        verify_safe_sklearn_artifact(tmp_path)


def test_artifact_digest_covers_names_and_contents(tmp_path):
    write_mlmodel(tmp_path)
    before = artifact_digest(tmp_path)
    (tmp_path / "model.skops").write_bytes(b"first")
    after = artifact_digest(tmp_path)
    assert before != after
    assert after.startswith("sha256:")


def test_prediction_restores_training_column_order(monkeypatch):
    class Predictor:
        feature_names_in_ = ["first", "second"]

        def predict(self, frame):
            assert list(frame.columns) == ["first", "second"]
            return [frame.iloc[0, 0]]

    loaded = LoadedModel("demo", "1", "sha256:test", Predictor())
    monkeypatch.setattr(registry, "load", lambda name, alias: loaded)
    outputs, _ = predict("demo", "champion", [{"second": 2, "first": 1}])
    assert outputs == [1]
