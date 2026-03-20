"""Data models for the Streamlit dashboard."""

from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import polars as pl
from pydantic import BaseModel, Field


class RevenueMetrics(BaseModel):
    """Daily revenue metrics with breakdown by type."""

    revenue_date: datetime
    total_revenue: float
    ticket_revenue: float
    concession_revenue: float


class ShowingRevenue(BaseModel):
    """Revenue data for a specific showing."""

    showing_id: str
    movie_title: str
    room_number: int
    start_time: datetime
    end_time: Optional[datetime] = None
    total_revenue: float
    ticket_count: int = 0
    status: str = Field(..., pattern="^(scheduled|live|finished)$")


class DashboardData(BaseModel):
    """Complete dashboard data container."""

    daily_metrics: List[RevenueMetrics]
    live_showings: List[ShowingRevenue]
    finished_showings: List[ShowingRevenue]
    scheduled_showings: List[ShowingRevenue]
    last_updated: datetime = Field(default_factory=datetime.now)


class FlinkResultRow(BaseModel):
    """Represents a row from Flink SQL Gateway result."""

    kind: str  # INSERT, UPDATE_AFTER, UPDATE_BEFORE, DELETE
    fields: List[Any]


class QueryResult(BaseModel):
    """Wrapper for Flink query results with metadata."""

    columns: List[str]
    rows: List[FlinkResultRow]
    result_type: str  # NOT_READY, PAYLOAD, EOS
    next_uri: Optional[str] = None
    job_id: Optional[str] = None


class SessionState(BaseModel):
    """Tracks the state of streaming queries and data."""

    session_handle: str
    operation_handles: Dict[str, str] = Field(default_factory=dict)
    daily_revenue_state: Dict[Tuple[str, ...], List[str]] = Field(default_factory=dict)
    live_showings_state: Dict[Tuple[str, ...], List[str]] = Field(default_factory=dict)
    finished_showings_state: Dict[Tuple[str, ...], List[str]] = Field(
        default_factory=dict
    )
    scheduled_showings_state: Dict[Tuple[str, ...], List[str]] = Field(
        default_factory=dict
    )
    last_poll_time: datetime = Field(default_factory=datetime.now)
    is_connected: bool = True
    # Track next result URIs for each query (for following the result chain)
    next_result_uris: Dict[str, str] = Field(default_factory=dict)
    # Cache column names for each query
    query_columns: Dict[str, List[str]] = Field(default_factory=dict)
    # Track job IDs for each query (to cancel them)
    job_ids: Dict[str, str] = Field(default_factory=dict)


def polars_to_revenue_metrics(df: pl.DataFrame) -> List[RevenueMetrics]:
    """Convert Polars DataFrame to RevenueMetrics list."""
    if df.is_empty():
        return []

    return [
        RevenueMetrics(
            revenue_date=row[0],
            total_revenue=float(row[1]) if row[1] is not None else 0.0,
            ticket_revenue=float(row[2]) if row[2] is not None else 0.0,
            concession_revenue=float(row[3]) if row[3] is not None else 0.0,
        )
        for row in df.rows()
    ]


def polars_to_showing_revenue(
    df: pl.DataFrame, has_duration: bool = False
) -> List[ShowingRevenue]:
    """Convert Polars DataFrame to ShowingRevenue list.
    
    Args:
        df: Polars DataFrame with showing data
        has_duration: If True, column 4 is duration_minutes (INT) and we calculate end_time
                      If False, column 4 is total_revenue (standard format)
    """
    if df.is_empty():
        return []

    showings = []
    for row in df.rows():
        if has_duration:
            # Format: showing_id, movie_title, room_number, start_time, duration_minutes, total_revenue, ticket_count, status
            start_time = _parse_datetime(row[3])
            duration_minutes = int(row[4]) if row[4] is not None else 0
            from datetime import timedelta
            end_time = start_time + timedelta(minutes=duration_minutes) if duration_minutes > 0 else None
            
            showing = ShowingRevenue(
                showing_id=str(row[0]) if row[0] is not None else "",
                movie_title=str(row[1]) if row[1] is not None else "",
                room_number=int(row[2]) if row[2] is not None else 0,
                start_time=start_time,
                end_time=end_time,
                total_revenue=float(row[5]) if row[5] is not None else 0.0,
                ticket_count=int(row[6]) if row[6] is not None else 0,
                status=str(row[7]) if row[7] is not None else "unknown",
            )
        else:
            # Standard format: showing_id, movie_title, room_number, start_time, total_revenue, ticket_count, status
            showing = ShowingRevenue(
                showing_id=str(row[0]) if row[0] is not None else "",
                movie_title=str(row[1]) if row[1] is not None else "",
                room_number=int(row[2]) if row[2] is not None else 0,
                start_time=_parse_datetime(row[3]),
                total_revenue=float(row[4]) if row[4] is not None else 0.0,
                ticket_count=int(row[5]) if row[5] is not None else 0,
                status=str(row[6]) if row[6] is not None else "unknown",
            )

        showings.append(showing)

    return showings


def _parse_datetime(value: Any) -> datetime:
    """Parse a value to datetime, handling various formats."""
    if value is None:
        return datetime.now()
    if isinstance(value, datetime):
        return value
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return datetime.now()
    return datetime.now()


def state_to_polars_df(
    columns: List[str], state: Dict[Tuple[str, ...], List[str]]
) -> pl.DataFrame:
    """Convert in-memory state dictionary to Polars DataFrame."""
    if not state or not columns:
        return pl.DataFrame()

    rows = list(state.values())
    if not rows:
        return pl.DataFrame()

    # Ensure all rows have the same length as columns
    normalized_rows = []
    for row in rows:
        normalized_row = row[: len(columns)] + [""] * max(0, len(columns) - len(row))
        normalized_rows.append(normalized_row)

    try:
        return pl.DataFrame(normalized_rows, schema=columns, orient="row")
    except Exception:
        # Fallback if schema inference fails
        return pl.DataFrame(normalized_rows, orient="row")


def extract_key_from_row(
    columns: List[str], row: List[str], key_columns: List[str]
) -> Tuple[str, ...]:
    """Extract key tuple from a row based on key column names."""
    if not key_columns or not columns:
        return tuple()

    column_indices = {}
    for i, col in enumerate(columns):
        column_indices[col] = i

    key = []
    for key_col in key_columns:
        idx = column_indices.get(key_col, -1)
        if idx >= 0 and idx < len(row):
            key.append(str(row[idx]))
        else:
            key.append("")

    return tuple(key)
