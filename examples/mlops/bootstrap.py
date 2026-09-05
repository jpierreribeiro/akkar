"""Register a small pickle-free reference model and promote it to champion."""

import mlflow
import mlflow.artifacts
import mlflow.sklearn
from mlflow import MlflowClient
from sklearn.datasets import load_iris
from sklearn.tree import DecisionTreeClassifier

from ml_service.config import settings
from ml_service.model_registry import artifact_digest

cfg = settings()
mlflow.set_tracking_uri(cfg.mlflow_tracking_uri)
x, y = load_iris(return_X_y=True, as_frame=True)
model = DecisionTreeClassifier(max_depth=3, random_state=7).fit(x, y)

with mlflow.start_run() as run:
    info = mlflow.sklearn.log_model(
        model,
        name="model",
        input_example=x.head(2),
        serialization_format="skops",
    )
    registered = mlflow.register_model(info.model_uri, cfg.model_name)

client = MlflowClient()
path = mlflow.artifacts.download_artifacts(artifact_uri=info.model_uri)
digest = artifact_digest(path)
client.set_model_version_tag(cfg.model_name, registered.version, "artifact_digest", digest)
client.set_model_version_tag(cfg.model_name, registered.version, "validation_status", "passed")
client.set_registered_model_alias(cfg.model_name, "candidate", registered.version)
client.set_registered_model_alias(cfg.model_name, "champion", registered.version)
print(f"registered {cfg.model_name}/{registered.version} {digest}")
