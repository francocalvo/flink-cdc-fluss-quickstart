"""Main Streamlit dashboard application."""

import time
from datetime import datetime
from typing import Optional

import polars as pl
import plotly.graph_objects as go
import streamlit as st

import config
import queries
from flink_client import FlinkSQLGatewayClient, FlinkClientError
from models import (
    DashboardData,
    polars_to_revenue_metrics,
    polars_to_showing_revenue,
    state_to_polars_df,
)


@st.cache_resource
def get_flink_client() -> FlinkSQLGatewayClient:
    """Initialize and cache Flink client."""
    return FlinkSQLGatewayClient(
        gateway_url=config.FLINK_GATEWAY_URL,
        timeout=config.FLINK_TIMEOUT,
        poll_interval_ms=config.FLINK_POLL_INTERVAL_MS,
        flink_rest_url=config.FLINK_REST_URL,
    )


def initialize_session() -> None:
    """Initialize Streamlit session state."""
    if "flink_connected" not in st.session_state:
        st.session_state.flink_connected = False

    if "last_update" not in st.session_state:
        st.session_state.last_update = datetime.now()

    if "dashboard_data" not in st.session_state:
        st.session_state.dashboard_data = DashboardData(
            daily_metrics=[],
            live_showings=[],
            finished_showings=[],
            scheduled_showings=[],
        )

    if "session_state" not in st.session_state:
        st.session_state.session_state = None

    if "error_message" not in st.session_state:
        st.session_state.error_message = ""

    if "debug_info" not in st.session_state:
        st.session_state.debug_info = []

    if "poll_count" not in st.session_state:
        st.session_state.poll_count = 0

    if "poll_status" not in st.session_state:
        st.session_state.poll_status = "Not started"

    if "render_id" not in st.session_state:
        st.session_state.render_id = 0


def connect_to_flink() -> bool:
    """Establish connection to Flink SQL Gateway."""
    client = get_flink_client()

    try:
        # Always try to reconnect if not connected
        if not client.is_connected():
            # Clear any previous session state
            if client.session_state is not None:
                try:
                    client.disconnect()
                except Exception:
                    pass
                client.session_state = None
            
            client.connect(properties=config.FLINK_SESSION_PROPERTIES)

        # Create Fluss catalog (if not exists) and configure session
        client.configure_session(queries.CREATE_CATALOG_QUERY)
        client.configure_session(queries.CATALOG_CONFIG)
        client.configure_session(queries.DATABASE_CONFIG)

        # Execute initial queries
        client.execute_query("daily_revenue", queries.DAILY_REVENUE_QUERY)
        client.execute_query("live_showings", queries.LIVE_SHOWINGS_QUERY)
        client.execute_query("finished_showings", queries.FINISHED_SHOWINGS_QUERY)
        client.execute_query("scheduled_showings", queries.SCHEDULED_SHOWINGS_QUERY)

        st.session_state.session_state = client.session_state
        st.session_state.flink_connected = True
        st.session_state.error_message = ""
        return True

    except FlinkClientError as e:
        st.session_state.error_message = f"Failed to connect to Flink: {e}"
        st.session_state.flink_connected = False
        return False
    except Exception as e:
        st.session_state.error_message = f"Unexpected error: {type(e).__name__}: {e}"
        st.session_state.flink_connected = False
        return False


def update_dashboard_data() -> None:
    """Poll Flink for updates and refresh dashboard data."""
    if not st.session_state.flink_connected:
        st.session_state.poll_status = "❌ Not connected"
        return

    client = get_flink_client()
    st.session_state.poll_count += 1
    st.session_state.poll_status = f"🔄 Polling... (#{st.session_state.poll_count})"

    try:
        # Poll each query for new results
        queries_to_update = [
            ("daily_revenue", "revenue_date"),
            ("live_showings", "showing_id"),
            ("finished_showings", "showing_id"),
            ("scheduled_showings", "showing_id"),
        ]

        updated_any = False
        debug_info = []
        total_rows = 0

        for query_name, sort_column in queries_to_update:
            result = client.poll_results(query_name, row_format="JSON")

            if result:
                row_count = len(result.rows)
                total_rows += row_count
                debug_info.append(f"{query_name}: type={result.result_type}, rows={row_count}")
                
                if result.rows:
                    # Get state dictionary for this query
                    state_attr = f"{query_name}_state"
                    if hasattr(st.session_state.session_state, state_attr):
                        state = getattr(st.session_state.session_state, state_attr)
                    else:
                        state = {}

                    # Apply changes
                    key_cols = queries.QUERY_KEY_COLUMNS.get(query_name, ["id"])
                    mutations = client.apply_changelog_to_state(
                        result.columns, state, result.rows, key_cols
                    )

                    if mutations > 0:
                        updated_any = True
                        setattr(st.session_state.session_state, state_attr, state)
                        debug_info[-1] += f", mutations={mutations}, state_size={len(state)}"
            else:
                debug_info.append(f"{query_name}: ⏳ waiting (NOT_READY)")

        # Store debug info for display
        st.session_state.debug_info = debug_info

        if updated_any:
            _refresh_dashboard_data_from_states()
            st.session_state.last_update = datetime.now()
            st.session_state.poll_status = f"✅ Got {total_rows} rows (poll #{st.session_state.poll_count})"
        else:
            st.session_state.poll_status = f"⏳ Waiting for data... (poll #{st.session_state.poll_count})"

    except FlinkClientError as e:
        st.session_state.error_message = f"Error polling Flink: {e}"
        st.session_state.flink_connected = False
        st.session_state.poll_status = f"❌ Error: {e}"


def _refresh_dashboard_data_from_states() -> None:
    """Convert state dictionaries to dashboard data models."""
    if not st.session_state.session_state:
        return

    # Daily revenue metrics
    daily_df = state_to_polars_df(
        ["revenue_date", "total_revenue", "ticket_revenue", "concession_revenue"],
        st.session_state.session_state.daily_revenue_state,
    )
    daily_metrics = polars_to_revenue_metrics(daily_df)

    # Live showings
    live_df = state_to_polars_df(
        [
            "showing_id",
            "movie_title",
            "room_number",
            "start_time",
            "total_revenue",
            "ticket_count",
            "status",
        ],
        st.session_state.session_state.live_showings_state,
    )
    live_showings = polars_to_showing_revenue(live_df)

    # Finished showings (with duration_minutes instead of end_time)
    finished_df = state_to_polars_df(
        [
            "showing_id",
            "movie_title",
            "room_number",
            "start_time",
            "duration_minutes",
            "total_revenue",
            "ticket_count",
            "status",
        ],
        st.session_state.session_state.finished_showings_state,
    )
    finished_showings = polars_to_showing_revenue(finished_df, has_duration=True)

    # Scheduled showings
    scheduled_df = state_to_polars_df(
        [
            "showing_id",
            "movie_title",
            "room_number",
            "scheduled_time",
            "presale_revenue",
            "ticket_count",
            "status",
        ],
        st.session_state.session_state.scheduled_showings_state,
    )
    scheduled_showings = polars_to_showing_revenue(scheduled_df)

    # Update session state
    st.session_state.dashboard_data = DashboardData(
        daily_metrics=daily_metrics,
        live_showings=live_showings,
        finished_showings=finished_showings,
        scheduled_showings=scheduled_showings,
    )


def _timestamp_or(value: Optional[datetime], fallback: float) -> float:
    """Return a safe timestamp for sorting, using fallback when unavailable."""
    try:
        if isinstance(value, datetime):
            return value.timestamp()
    except Exception:
        pass
    return fallback


def render_revenue_chart() -> None:
    """Render the revenue stacked area chart by minute."""
    st.subheader("📈 Revenue Trends by Minute (Last 30 Minutes)")

    metrics = st.session_state.dashboard_data.daily_metrics

    if not metrics:
        st.info("No revenue data available yet.")
        return

    # Sort by date
    metrics.sort(key=lambda x: x.revenue_date)

    dates = [m.revenue_date for m in metrics]
    ticket_revenue = [m.ticket_revenue for m in metrics]
    concession_revenue = [m.concession_revenue for m in metrics]

    fig = go.Figure()

    # Add stacked area traces (order matters for stacking)
    fig.add_trace(
        go.Scatter(
            x=dates,
            y=ticket_revenue,
            mode="lines",
            name="Ticket Revenue",
            line=dict(width=0.5, color="#ff7f0e"),
            stackgroup="one",
            fillcolor="rgba(255, 127, 14, 0.6)",
        )
    )

    fig.add_trace(
        go.Scatter(
            x=dates,
            y=concession_revenue,
            mode="lines",
            name="Concession Revenue",
            line=dict(width=0.5, color="#2ca02c"),
            stackgroup="one",
            fillcolor="rgba(44, 160, 44, 0.6)",
        )
    )

    fig.update_layout(
        title="Revenue Breakdown by Minute (Last 30 Minutes)",
        xaxis_title="Time",
        yaxis_title="Revenue ($)",
        hovermode="x unified",
        height=config.CHART_HEIGHT,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
    )

    st.plotly_chart(fig, use_container_width=True, key=f"revenue_chart_{st.session_state.render_id}")


def render_showings_tables() -> None:
    """Render the three live updating tables."""
    col1, col2, col3 = st.columns(3)

    with col1:
        st.subheader("🎬 Live Showings")
        # Sort by total_revenue descending
        live_showings = sorted(
            st.session_state.dashboard_data.live_showings,
            key=lambda x: (
                -float(x.total_revenue),
                _timestamp_or(x.start_time, float("inf")),
                x.movie_title,
            ),
        )[: config.MAX_ROWS_PER_TABLE]

        if live_showings:
            live_data = {
                "Movie": [s.movie_title for s in live_showings],
                "Room": [s.room_number for s in live_showings],
                "Start": [s.start_time.strftime("%H:%M") for s in live_showings],
                "Tickets": [int(s.ticket_count) for s in live_showings],
                "Revenue": [float(s.total_revenue) for s in live_showings],
            }

            df = pl.DataFrame(live_data).to_pandas()
            # Sort by Revenue descending to ensure proper display order
            df = df.sort_values("Revenue", ascending=False).reset_index(drop=True)
            
            st.dataframe(
                df,
                use_container_width=True,
                hide_index=True,
                column_config={
                    "Revenue": st.column_config.NumberColumn(
                        "Revenue",
                        format="$%.2f",
                    ),
                    "Tickets": st.column_config.NumberColumn(
                        "Tickets",
                        format="%d",
                    )
                },
                key=f"live_table_{st.session_state.render_id}"
            )
        else:
            st.info("No live showings.")

    with col2:
        st.subheader("✅ Finished Showings")
        # Sort by end_time descending (most recent finished first), fall back to start_time
        finished_showings = sorted(
            st.session_state.dashboard_data.finished_showings,
            key=lambda x: (
                _timestamp_or(x.end_time or x.start_time, float("-inf")),
                _timestamp_or(x.start_time, float("-inf")),
            ),
            reverse=True,
        )[: config.MAX_ROWS_PER_TABLE]

        if finished_showings:
            finished_data = {
                "Movie": [s.movie_title for s in finished_showings],
                "Room": [s.room_number for s in finished_showings],
                "Start": [s.start_time.strftime("%H:%M") for s in finished_showings],
                "End": [s.end_time.strftime("%H:%M") if s.end_time else "N/A" for s in finished_showings],
                "Tickets": [int(s.ticket_count) for s in finished_showings],
                "Revenue": [float(s.total_revenue) for s in finished_showings],
            }

            df = pl.DataFrame(finished_data).to_pandas()
            # Already sorted by end_time in Python, maintain that order
            
            st.dataframe(
                df,
                use_container_width=True,
                hide_index=True,
                column_config={
                    "Revenue": st.column_config.NumberColumn(
                        "Revenue",
                        format="$%.2f",
                    ),
                    "Tickets": st.column_config.NumberColumn(
                        "Tickets",
                        format="%d",
                    )
                },
                key=f"finished_table_{st.session_state.render_id}"
            )
        else:
            st.info("No finished showings.")

    with col3:
        st.subheader("📅 Scheduled Showings")
        # Sort by start_time ascending (next showings first)
        scheduled_showings = sorted(
            st.session_state.dashboard_data.scheduled_showings,
            key=lambda x: (
                _timestamp_or(x.start_time, float("inf")),
                x.movie_title,
            ),
        )[: config.MAX_ROWS_PER_TABLE]

        if scheduled_showings:
            scheduled_data = {
                "Movie": [s.movie_title for s in scheduled_showings],
                "Room": [s.room_number for s in scheduled_showings],
                "Time": [s.start_time.strftime("%H:%M") for s in scheduled_showings],
                "Tickets": [int(s.ticket_count) for s in scheduled_showings],
                "Pre-sales": [float(s.total_revenue) for s in scheduled_showings],
            }

            df = pl.DataFrame(scheduled_data).to_pandas()
            # Already sorted by start_time in Python, maintain that order
            
            st.dataframe(
                df,
                use_container_width=True,
                hide_index=True,
                column_config={
                    "Pre-sales": st.column_config.NumberColumn(
                        "Pre-sales",
                        format="$%.2f",
                    ),
                    "Tickets": st.column_config.NumberColumn(
                        "Tickets",
                        format="%d",
                    )
                },
                key=f"scheduled_table_{st.session_state.render_id}"
            )
        else:
            st.info("No scheduled showings.")


def disconnect_from_flink() -> None:
    """Disconnect from Flink SQL Gateway and stop all queries."""
    client = get_flink_client()
    
    # Get job IDs before disconnecting for logging
    job_ids = {}
    if client.session_state:
        job_ids = dict(client.session_state.job_ids)
    
    cancellation_results = {}
    try:
        cancellation_results = client.disconnect()
    except Exception as e:
        st.session_state.error_message = f"Error during disconnect: {e}"
    
    # Build status message with cancellation results
    cancelled = [k for k, v in cancellation_results.items() if v]
    failed = [k for k, v in cancellation_results.items() if not v]
    
    status_parts = []
    if cancelled:
        status_parts.append(f"✅ Cancelled: {', '.join(cancelled)}")
    if failed:
        status_parts.append(f"⚠️ Failed to cancel: {', '.join(failed)}")
    if not status_parts:
        status_parts.append("No active jobs to cancel")
    
    # Reset all session state
    st.session_state.flink_connected = False
    st.session_state.session_state = None
    st.session_state.poll_count = 0
    st.session_state.poll_status = f"Disconnected - {'; '.join(status_parts)}"
    st.session_state.debug_info = [
        f"{k}: job_id={job_ids.get(k, 'N/A')}, cancelled={v}" 
        for k, v in cancellation_results.items()
    ]
    
    # Clear the cached client resource
    get_flink_client.clear()


def render_status_bar() -> None:
    """Render connection status and last update time."""
    col1, col2, col3, col4 = st.columns([1, 1, 2, 1])

    with col1:
        if st.session_state.flink_connected:
            st.success("🟢 Connected to Flink")
        else:
            st.error("🔴 Disconnected from Flink")

    with col2:
        if st.session_state.flink_connected:
            if st.button("⏹️ Disconnect", key=f"disconnect_btn_{st.session_state.render_id}", type="secondary"):
                disconnect_from_flink()
                st.rerun()
        else:
            if st.button("🔄 Retry Connection", key=f"retry_btn_{st.session_state.render_id}"):
                st.session_state.error_message = ""
                st.rerun()

    with col3:
        if st.session_state.error_message:
            st.error(f"Error: {st.session_state.error_message}")

    with col4:
        last_update = st.session_state.last_update.strftime("%H:%M:%S")
        st.info(f"Last Update: {last_update}")


def main() -> None:
    """Main application entry point."""
    st.set_page_config(**config.PAGE_CONFIG)

    st.title("🎬 Cinema Revenue Dashboard")
    st.markdown("Real-time revenue tracking powered by Flink SQL Gateway")
    
    # Show config in sidebar
    with st.sidebar:
        st.subheader("Configuration")
        st.text(f"Gateway: {config.FLINK_GATEWAY_URL}")
        client = get_flink_client()
        st.text(f"REST API: {client.flink_rest_url}")
        st.text(f"Fluss: {config.FLUSS_BOOTSTRAP_SERVER}")

    initialize_session()

    # Connection management
    if not st.session_state.flink_connected:
        with st.spinner("Connecting to Flink SQL Gateway..."):
            connect_to_flink()

    # Auto-refresh mechanism
    if st.session_state.flink_connected:
        # Create placeholder for auto-refresh
        placeholder = st.empty()

        while True:
            # Increment render ID for unique keys
            st.session_state.render_id += 1
            
            with placeholder.container():
                # Update data
                update_dashboard_data()

                # Render status
                render_status_bar()
                
                # Poll status and debug info
                st.caption(f"Poll Status: {st.session_state.poll_status}")
                with st.expander("🔍 Debug Info", expanded=False):
                    st.text(f"Poll count: {st.session_state.poll_count}")
                    st.divider()
                    if st.session_state.debug_info:
                        for info in st.session_state.debug_info:
                            st.text(info)
                    else:
                        st.text("No poll results yet")

                # Render visualizations
                render_revenue_chart()
                st.divider()
                render_showings_tables()

                # Auto-refresh interval
                time.sleep(config.STREAMLIT_AUTO_REFRESH_INTERVAL)

                # Clear for next iteration
                placeholder.empty()
    else:
        render_status_bar()
        st.stop()


if __name__ == "__main__":
    main()
