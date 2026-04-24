from fastapi import APIRouter

from ..models import (
    IoTDeploymentCreateRequest,
    IoTDeploymentExistsResponse,
    IoTDeploymentResponse,
    IoTDeviceRegisterRequest,
    IoTDeviceRegisterResponse,
    IoTOrphanTelemetrySummary,
    IoTTelemetryIngestRequest,
    IoTTelemetryResponse,
)
from ..questdb import (
    check_deployment_exists,
    get_orphan_telemetry_summary,
    ingest_deployment,
    ingest_device_registration,
    ingest_telemetry,
)

router = APIRouter(prefix="/api/iot", tags=["iot-ingest"])


@router.post("/devices/register", response_model=IoTDeviceRegisterResponse)
async def register_iot_device(payload: IoTDeviceRegisterRequest):
    return await ingest_device_registration(payload)


@router.post("/deployments", response_model=IoTDeploymentResponse)
async def create_iot_deployment(payload: IoTDeploymentCreateRequest):
    return await ingest_deployment(payload)


@router.post("/telemetry", response_model=IoTTelemetryResponse)
async def ingest_iot_telemetry(payload: IoTTelemetryIngestRequest):
    return await ingest_telemetry(payload)


@router.get(
    "/deployments/{deployment_id}/exists",
    response_model=IoTDeploymentExistsResponse,
)
async def deployment_exists(deployment_id: str):
    return await check_deployment_exists(deployment_id)


@router.get("/orphans", response_model=IoTOrphanTelemetrySummary)
async def orphan_telemetry_summary():
    return await get_orphan_telemetry_summary()
