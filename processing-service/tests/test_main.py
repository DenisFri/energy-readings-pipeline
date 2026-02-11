import json
from unittest.mock import patch

from fastapi.testclient import TestClient

# Patch the lifespan before importing the app so the background consumer
# doesn't start during tests (it would try to connect to Redis).
with patch("main.lifespan") as mock_lifespan:
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def _noop_lifespan(app):
        yield

    mock_lifespan.side_effect = _noop_lifespan

    # Re-create the app with the patched lifespan
    import main

    main.app.router.lifespan_context = _noop_lifespan
    from main import app

client = TestClient(app)

SAMPLE_READING = {
    "stream_id": "1705312200000-0",
    "site_id": "site-001",
    "device_id": "meter-42",
    "power_reading": 1500.5,
    "timestamp": "2024-01-15T10:30:00Z",
    "ingested_at": "2024-01-15T10:30:00.123456",
}


class TestGetSiteReadings:
    @patch("main.redis_client")
    def test_returns_readings_for_site(self, mock_redis):
        mock_redis.zrange.return_value = [json.dumps(SAMPLE_READING)]

        response = client.get("/sites/site-001/readings")

        assert response.status_code == 200
        data = response.json()
        assert data["site_id"] == "site-001"
        assert len(data["readings"]) == 1
        assert data["readings"][0]["device_id"] == "meter-42"
        assert data["readings"][0]["power_reading"] == 1500.5

    @patch("main.redis_client")
    def test_empty_site_returns_empty_list(self, mock_redis):
        mock_redis.zrange.return_value = []

        response = client.get("/sites/unknown-site/readings")

        assert response.status_code == 200
        data = response.json()
        assert data["site_id"] == "unknown-site"
        assert data["readings"] == []

    @patch("main.redis_client")
    def test_multiple_readings_returned(self, mock_redis):
        reading2 = {**SAMPLE_READING, "power_reading": 2000.0, "timestamp": "2024-01-15T11:00:00Z"}
        mock_redis.zrange.return_value = [
            json.dumps(SAMPLE_READING),
            json.dumps(reading2),
        ]

        response = client.get("/sites/site-001/readings")

        assert response.status_code == 200
        data = response.json()
        assert len(data["readings"]) == 2

    @patch("main.redis_client")
    def test_redis_connection_error_returns_503(self, mock_redis):
        import redis

        mock_redis.zrange.side_effect = redis.ConnectionError("Connection refused")

        response = client.get("/sites/site-001/readings")
        assert response.status_code == 503


class TestHealthCheck:
    @patch("main.redis_client")
    def test_healthy_when_redis_connected(self, mock_redis):
        mock_redis.ping.return_value = True

        response = client.get("/health")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "healthy"
        assert data["redis_connected"] is True

    @patch("main.redis_client")
    def test_degraded_when_redis_disconnected(self, mock_redis):
        import redis

        mock_redis.ping.side_effect = redis.ConnectionError()

        response = client.get("/health")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "degraded"
        assert data["redis_connected"] is False


class TestTimestampToScore:
    def test_valid_iso_timestamp(self):
        from main import _timestamp_to_score

        score = _timestamp_to_score("2024-01-15T10:30:00Z")
        assert score > 0

    def test_invalid_timestamp_returns_zero(self):
        from main import _timestamp_to_score

        assert _timestamp_to_score("not-a-timestamp") == 0.0

    def test_empty_string_returns_zero(self):
        from main import _timestamp_to_score

        assert _timestamp_to_score("") == 0.0
