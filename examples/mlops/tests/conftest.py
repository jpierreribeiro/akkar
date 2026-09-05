import os

os.environ.setdefault("ML_INTERNAL_TOKEN", "test-token-that-is-at-least-32-characters")
os.environ.setdefault("ML_DATABASE_URL", "postgresql://unused")
os.environ.setdefault("ML_REDIS_URL", "redis://unused")
os.environ.setdefault("ML_MLFLOW_TRACKING_URI", "http://unused")
os.environ.setdefault("ML_S3_ENDPOINT_URL", "http://unused")
os.environ.setdefault("ML_S3_ACCESS_KEY", "unused")
os.environ.setdefault("ML_S3_SECRET_KEY", "unused-secret")
