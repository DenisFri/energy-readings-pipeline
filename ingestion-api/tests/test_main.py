from unittest.mock import patch, MagicMock

import pytest
from fastapi.testclient import TestClient

from main import app

client = TestClient(app)

VALID_READING = {
    "site_id": "site-001",
    "device_id": "meter-42",
    "power_reading": 1500.5,
    "timestamp": "2024-01-15T10:30:00Z",
}


class TestPostReadings:
    @patch("main.redis_client")
    def test_success_returns_201_accepted(self, mock_redis):
        mock_redis.xadd.return_value = "1705312200000-0"

        response = client.post("/readings", json=VALID_READING)

        assert response.status_code == 201
        data = response.json()
        assert data["status"] == "accepted"
        assert data["stream_id"] == "1705312200000-0"

    @patch("main.redis_client")
    def test_response_has_no_extra_fields(self, mock_redis):
        mock_redis.xadd.return_value = "1705312200000-0"

        response = client.post("/readings", json=VALID_READING)

        data = response.json()
        assert set(data.keys()) == {"status", "stream_id"}

    def test_missing_site_id_returns_422(self):
        reading = {**VALID_READING, "site_id": ""}
        response = client.post("/readings", json=reading)
        assert response.status_code == 422

    def test_missing_device_id_returns_422(self):
        reading = {**VALID_READING, "device_id": ""}
        response = client.post("/readings", json=reading)
        assert response.status_code == 422

    def test_missing_field_returns_422(self):
        reading = {"site_id": "site-001", "device_id": "meter-42"}
        response = client.post("/readings", json=reading)
        assert response.status_code == 422

    def test_negative_power_reading_returns_422(self):
        reading = {**VALID_READING, "power_reading": -100}
        response = client.post("/readings", json=reading)
        assert response.status_code == 422

    def test_invalid_timestamp_returns_422(self):
        reading = {**VALID_READING, "timestamp": "not-a-timestamp"}
        response = client.post("/readings", json=reading)
        assert response.status_code == 422

    @patch("main.redis_client")
    def test_redis_connection_error_returns_503(self, mock_redis):
        import redis

        mock_redis.xadd.side_effect = redis.ConnectionError("Connection refused")

        response = client.post("/readings", json=VALID_READING)
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
