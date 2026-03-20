"""Configuration settings for the dashboard."""

import os
from typing import Dict, Any

# Flink SQL Gateway settings
FLINK_GATEWAY_URL = os.getenv("FLINK_GATEWAY_URL", "http://localhost:8083")
# Flink REST API URL (for job cancellation) - defaults to gateway URL with port 8081
FLINK_REST_URL = os.getenv("FLINK_REST_URL", "")  # Empty means derive from gateway URL
FLINK_TIMEOUT = float(os.getenv("FLINK_TIMEOUT", "30.0"))
FLINK_POLL_INTERVAL_MS = int(os.getenv("FLINK_POLL_INTERVAL_MS", "250"))

# Fluss catalog settings
FLUSS_BOOTSTRAP_SERVER = os.getenv("FLUSS_BOOTSTRAP_SERVER", "192.168.1.202:9123")

# Streamlit refresh settings
STREAMLIT_AUTO_REFRESH_INTERVAL = int(
    os.getenv("STREAMLIT_AUTO_REFRESH_INTERVAL", "1")
)  # seconds
STREAMLIT_RENDER_MIN_INTERVAL_MS = int(
    os.getenv("STREAMLIT_RENDER_MIN_INTERVAL_MS", "800")
)

# Dashboard display settings
MAX_ROWS_PER_TABLE = int(os.getenv("MAX_ROWS_PER_TABLE", "10"))
CHART_HEIGHT = int(os.getenv("CHART_HEIGHT", "400"))
CHART_DATE_RANGE_DAYS = int(os.getenv("CHART_DATE_RANGE_DAYS", "30"))

# Flink session properties
FLINK_SESSION_PROPERTIES: Dict[str, Any] = {
    "execution.runtime-mode": "streaming",
    "sql-client.execution.result-mode": "changelog",
}

# Streamlit page configuration
PAGE_CONFIG = {
    "page_title": "Cinema Revenue Dashboard",
    "page_icon": "🎬",
    "layout": "wide",
    "initial_sidebar_state": "collapsed",
}
