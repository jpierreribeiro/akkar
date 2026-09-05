from typing import Annotated, Any

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator
Name = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")]
Uri = Annotated[str, StringConstraints(pattern=r"^s3://[A-Za-z0-9._-]+/.+")]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PredictionRequest(StrictModel):
    model_name: Name | None = None
    model_alias: Name | None = None
    inputs: list[dict[str, Any]] = Field(min_length=1, max_length=10_000)


class PredictionResponse(StrictModel):
    model_name: str
    model_version: str
    model_digest: str
    outputs: list[Any]


class BatchRequest(StrictModel):
    model_name: Name | None = None
    model_alias: Name | None = None
    input_uri: Uri
    input_version_id: str = Field(min_length=1, max_length=1024)
    input_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    parameters: dict[str, Any] = Field(default_factory=dict)

    @field_validator("input_version_id")
    @classmethod
    def versioned(cls, value: str) -> str:
        if value == "null":
            raise ValueError("an immutable object version is required")
        return value

    @field_validator("parameters")
    @classmethod
    def no_parameters(cls, value: dict[str, Any]) -> dict[str, Any]:
        if value:
            raise ValueError("parameters are not implemented")
        return value


class BatchAccepted(StrictModel):
    job_id: str
    state: str
    status_url: str
    duplicate: bool = False


class BatchStatus(StrictModel):
    job_id: str
    tenant_id: str
    state: str
    attempts: int
    model_name: str
    model_alias: str
    model_version: str | None
    model_digest: str | None
    input_uri: str
    output_uri: str | None
    error: str | None
    created_at: str
    started_at: str | None
    finished_at: str | None
