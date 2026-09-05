from functools import lru_cache

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="ML_", extra="ignore")

    internal_token: SecretStr = Field(min_length=32)
    database_url: str
    redis_url: str
    mlflow_tracking_uri: str
    model_name: str = "akkar-reference"
    model_alias: str = "champion"
    s3_endpoint_url: str
    s3_access_key: SecretStr
    s3_secret_key: SecretStr
    s3_region: str = "us-east-1"
    input_bucket: str = "ml-batch"
    output_bucket: str = "ml-batch"
    require_model_digest: bool = True
    max_body_bytes: int = Field(default=1024 * 1024, ge=1024, le=16 * 1024 * 1024)
    max_batch_input_bytes: int = Field(
        default=64 * 1024 * 1024, ge=1024, le=1024 * 1024 * 1024
    )
    max_batch_output_bytes: int = Field(
        default=128 * 1024 * 1024, ge=1024, le=1024 * 1024 * 1024
    )
    max_batch_rows: int = Field(default=100_000, ge=1, le=1_000_000)
    batch_task_time_limit_seconds: int = Field(default=900, ge=30, le=86_400)


@lru_cache
def settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
