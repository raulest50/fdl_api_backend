from typing import List, Optional

from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: str
    questdb: str
    version: str


class DeploymentNode(BaseModel):
    deployment_id: str = Field(alias="deploymentId")
    board_id: str = Field(alias="boardId")
    latitude: float
    longitude: float
    location_name: str = Field(alias="locationName")
    timestamp: str
    sensor_type: Optional[str] = Field(default=None, alias="sensorType")

    model_config = {
        "populate_by_name": True,
    }


class DeploymentDetail(BaseModel):
    deployment_id: str = Field(alias="deploymentId")
    board_id: str = Field(alias="boardId")
    latitude: float
    longitude: float
    location_name: str = Field(alias="locationName")
    timestamp: str
    sensor_type: Optional[str] = Field(default=None, alias="sensorType")
    latest_co2: Optional[float] = Field(default=None, alias="latestCo2")
    latest_temp: Optional[float] = Field(default=None, alias="latestTemp")
    latest_rh: Optional[float] = Field(default=None, alias="latestRh")
    latest_errors: Optional[int] = Field(default=None, alias="latestErrors")
    variables: List[str]

    model_config = {
        "populate_by_name": True,
    }


class TelemetryPoint(BaseModel):
    timestamp: str
    co2: Optional[float] = None
    temp: Optional[float] = None
    rh: Optional[float] = None


class IoTDeviceRegisterRequest(BaseModel):
    board_id: str = Field(alias="boardId", min_length=1)
    sensor_type: str = Field(alias="sensorType", min_length=1)
    timestamp: str | int | float

    model_config = {
        "populate_by_name": True,
    }


class IoTDeploymentCreateRequest(BaseModel):
    deployment_id: str = Field(alias="deploymentId", min_length=1)
    board_id: str = Field(alias="boardId", min_length=1)
    latitude: float
    longitude: float
    location_name: str = Field(default="", alias="locationName")
    timestamp: str | int | float

    model_config = {
        "populate_by_name": True,
    }


class IoTTelemetryIngestRequest(BaseModel):
    deployment_id: str = Field(alias="deploymentId", min_length=1)
    co2: float
    temp: float
    rh: float
    errors: int
    timestamp: str | int | float

    model_config = {
        "populate_by_name": True,
    }


class IoTDeviceRegisterResponse(BaseModel):
    status: str
    board_id: str = Field(alias="boardId")

    model_config = {
        "populate_by_name": True,
    }


class IoTDeploymentResponse(BaseModel):
    status: str
    deployment_id: str = Field(alias="deploymentId")

    model_config = {
        "populate_by_name": True,
    }


class IoTTelemetryResponse(BaseModel):
    status: str
    deployment_id: str = Field(alias="deploymentId")

    model_config = {
        "populate_by_name": True,
    }


class IoTDeploymentExistsResponse(BaseModel):
    exists: bool
    deployment_id: str = Field(alias="deploymentId")
    board_id: Optional[str] = Field(default=None, alias="boardId")

    model_config = {
        "populate_by_name": True,
    }


class IoTOrphanTelemetrySummary(BaseModel):
    orphan_telemetry_count: int = Field(alias="orphanTelemetryCount")
    orphan_deployment_ids: List[str] = Field(alias="orphanDeploymentIds")

    model_config = {
        "populate_by_name": True,
    }
