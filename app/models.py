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
