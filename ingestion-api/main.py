"""
Ingestion API - Energy Readings Pipeline
Accepts energy readings and pushes them to a Redis stream.
"""

import os
from datetime import datetime

import redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, field_validator

app = FastAPI(
    title="Energy Readings Ingestion API",
    description="API for ingesting energy readings into the pipeline",
    version="1.0.0",
)

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
REDIS_STREAM = os.getenv("REDIS_STREAM", "energy_readings")

redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


class EnergyReading(BaseModel):
    """Schema for energy reading data."""

    site_id: str = Field(..., min_length=1, description="Unique identifier for the site")
    device_id: str = Field(..., min_length=1, description="Unique identifier for the device")
    power_reading: float = Field(..., ge=0, description="Power reading in watts")
    timestamp: str = Field(..., description="ISO 8601 formatted timestamp")

    @field_validator("timestamp")
    @classmethod
    def validate_timestamp(cls, v: str) -> str:
        """Validate that timestamp is in ISO 8601 format."""
        try:
            datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError:
            raise ValueError("timestamp must be in ISO 8601 format")
        return v


class ReadingResponse(BaseModel):
    """Response model for successful reading ingestion."""

    status: str
    stream_id: str


class HealthResponse(BaseModel):
    """Response model for health check."""

    status: str
    redis_connected: bool


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    try:
        redis_client.ping()
        redis_connected = True
    except redis.ConnectionError:
        redis_connected = False

    return HealthResponse(
        status="healthy" if redis_connected else "degraded",
        redis_connected=redis_connected,
    )


@app.post("/readings", response_model=ReadingResponse, status_code=201)
async def ingest_reading(reading: EnergyReading):
    """
    Ingest an energy reading into the Redis stream.

    The reading is validated against the schema and pushed to the
    'energy_readings' Redis stream using XADD.
    """
    try:
        stream_data = {
            "site_id": reading.site_id,
            "device_id": reading.device_id,
            "power_reading": str(reading.power_reading),
            "timestamp": reading.timestamp,
            "ingested_at": datetime.utcnow().isoformat(),
        }

        stream_id = redis_client.xadd(REDIS_STREAM, stream_data)

        return ReadingResponse(
            status="accepted",
            stream_id=stream_id,
        )

    except redis.ConnectionError as e:
        raise HTTPException(
            status_code=503,
            detail=f"Redis connection error: {str(e)}",
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to ingest reading: {str(e)}",
        )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
