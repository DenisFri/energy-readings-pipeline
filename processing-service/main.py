"""
Processing Service - Energy Readings Pipeline
Background worker that reads from the energy_readings Redis stream
using a consumer group and processes the readings.
"""

import os
import asyncio
import logging
from contextlib import asynccontextmanager

import redis
from fastapi import FastAPI

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
REDIS_STREAM = os.getenv("REDIS_STREAM", "energy_readings")
CONSUMER_GROUP = os.getenv("CONSUMER_GROUP", "processing_group")
CONSUMER_NAME = os.getenv("CONSUMER_NAME", os.getenv("HOSTNAME", "processor-1"))

redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

# Background task reference
background_task = None


def ensure_consumer_group():
    """Create the consumer group if it doesn't exist."""
    try:
        redis_client.xgroup_create(
            REDIS_STREAM,
            CONSUMER_GROUP,
            id="0",
            mkstream=True,
        )
        logger.info(f"Created consumer group '{CONSUMER_GROUP}' for stream '{REDIS_STREAM}'")
    except redis.ResponseError as e:
        if "BUSYGROUP" in str(e):
            logger.info(f"Consumer group '{CONSUMER_GROUP}' already exists")
        else:
            raise


async def process_reading(stream_id: str, data: dict):
    """
    Process a single energy reading.

    This is a skeleton implementation. Add your processing logic here.

    Args:
        stream_id: The Redis stream entry ID
        data: The reading data dictionary
    """
    logger.info(f"Processing reading {stream_id}: {data}")

    # TODO: Implement your processing logic here
    # Examples:
    # - Store in a time-series database
    # - Calculate aggregations
    # - Detect anomalies
    # - Trigger alerts

    site_id = data.get("site_id")
    device_id = data.get("device_id")
    power_reading = float(data.get("power_reading", 0))
    timestamp = data.get("timestamp")

    # Placeholder processing - simulate some work
    await asyncio.sleep(0.01)

    logger.info(
        f"Processed reading for site={site_id}, device={device_id}, "
        f"power={power_reading}W at {timestamp}"
    )


async def consume_stream():
    """
    Background worker that consumes messages from the Redis stream.

    Uses XREADGROUP with a consumer group to enable distributed processing
    and message acknowledgment.
    """
    logger.info(f"Starting stream consumer: {CONSUMER_NAME}")
    ensure_consumer_group()

    while True:
        try:
            # Read new messages from the stream
            messages = redis_client.xreadgroup(
                CONSUMER_GROUP,
                CONSUMER_NAME,
                {REDIS_STREAM: ">"},
                count=10,
                block=5000,
            )

            if messages:
                for stream_name, stream_messages in messages:
                    for stream_id, data in stream_messages:
                        try:
                            await process_reading(stream_id, data)

                            # Acknowledge the message after successful processing
                            redis_client.xack(REDIS_STREAM, CONSUMER_GROUP, stream_id)
                            logger.debug(f"Acknowledged message {stream_id}")

                        except Exception as e:
                            logger.error(f"Error processing message {stream_id}: {e}")
                            # Message remains in pending state for retry

        except redis.ConnectionError as e:
            logger.error(f"Redis connection error: {e}")
            await asyncio.sleep(5)

        except Exception as e:
            logger.error(f"Unexpected error in consumer: {e}")
            await asyncio.sleep(1)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage application lifecycle - start/stop background worker."""
    global background_task

    # Start the background consumer
    background_task = asyncio.create_task(consume_stream())
    logger.info("Background stream consumer started")

    yield

    # Shutdown the background consumer
    if background_task:
        background_task.cancel()
        try:
            await background_task
        except asyncio.CancelledError:
            logger.info("Background stream consumer stopped")


app = FastAPI(
    title="Energy Readings Processing Service",
    description="Background service for processing energy readings from the stream",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    try:
        redis_client.ping()
        redis_connected = True
    except redis.ConnectionError:
        redis_connected = False

    return {
        "status": "healthy" if redis_connected else "degraded",
        "redis_connected": redis_connected,
        "consumer_name": CONSUMER_NAME,
        "consumer_group": CONSUMER_GROUP,
    }


@app.get("/metrics")
async def get_metrics():
    """Get processing metrics from the stream."""
    try:
        # Get stream info
        stream_info = redis_client.xinfo_stream(REDIS_STREAM)
        group_info = redis_client.xinfo_groups(REDIS_STREAM)

        return {
            "stream": {
                "length": stream_info.get("length", 0),
                "first_entry": stream_info.get("first-entry"),
                "last_entry": stream_info.get("last-entry"),
            },
            "consumer_groups": [
                {
                    "name": g["name"],
                    "consumers": g["consumers"],
                    "pending": g["pending"],
                }
                for g in group_info
            ],
        }
    except redis.ResponseError as e:
        return {"error": str(e)}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8001)
