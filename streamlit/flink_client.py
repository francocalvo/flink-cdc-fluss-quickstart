"""Flink SQL Gateway client for streaming queries."""

import json
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urljoin

import requests

from models import FlinkResultRow, QueryResult, SessionState


class FlinkClientError(Exception):
    """Custom exception for Flink client errors."""

    pass


class FlinkSQLGatewayClient:
    """Client for interacting with Flink SQL Gateway."""

    def __init__(
        self,
        gateway_url: str,
        timeout: float = 30.0,
        poll_interval_ms: int = 250,
        flink_rest_url: str = "",
    ):
        self.gateway_url = gateway_url.rstrip("/")
        self.timeout = timeout
        self.poll_interval_ms = poll_interval_ms
        self.session = requests.Session()
        self.base_url = ""
        self.session_state: Optional[SessionState] = None
        # Flink REST API URL (for cancelling jobs)
        # If not provided, derive from gateway URL (Gateway :8083 -> REST API :8081)
        if flink_rest_url:
            self.flink_rest_url = flink_rest_url.rstrip("/")
        else:
            self.flink_rest_url = self.gateway_url.replace(":8083", ":8081")

    def _http_json(
        self,
        method: str,
        url: str,
        params: Optional[Dict] = None,
        json_body: Optional[Dict] = None,
    ) -> Dict[str, Any]:
        """Make HTTP request and return JSON response."""
        try:
            resp = self.session.request(
                method, url, params=params, json=json_body, timeout=self.timeout
            )

            if resp.status_code >= 400:
                try:
                    error_data = resp.json()
                    raise FlinkClientError(
                        f"HTTP {resp.status_code} {url}\n{json.dumps(error_data, indent=2)}"
                    )
                except json.JSONDecodeError:
                    raise FlinkClientError(
                        f"HTTP {resp.status_code} {url}\n{resp.text}"
                    )

            return resp.json()

        except requests.RequestException as e:
            raise FlinkClientError(f"Request failed for {url}: {e}")
        except json.JSONDecodeError as e:
            raise FlinkClientError(f"Invalid JSON response from {url}: {e}")

    def connect(self, properties: Optional[Dict[str, str]] = None) -> None:
        """Establish connection and create session."""
        # Validate gateway endpoint
        info_url = f"{self.gateway_url}/info"
        self._http_json("GET", info_url)
        self.base_url = f"{self.gateway_url}/"

        # Create session
        session_payload = {}
        if properties:
            session_payload["properties"] = properties

        session_resp = self._http_json(
            "POST", urljoin(self.base_url, "sessions"), json_body=session_payload
        )

        session_handle = self._extract_handle(
            session_resp.get("sessionHandle")
            or session_resp.get("session_handle")
            or session_resp
        )

        self.session_state = SessionState(session_handle=session_handle)

    def disconnect(self) -> Dict[str, bool]:
        """Close all operations, cancel jobs, and close session.
        
        Returns a dict of {query_name: cancelled_successfully}.
        """
        cancellation_results: Dict[str, bool] = {}
        
        if not self.session_state:
            return cancellation_results
        
        # Best-effort: fetch any missing job IDs directly from the SQL Gateway
        # so we can cancel jobs even if we have not polled results yet.
        self._collect_job_ids_from_operations()

        # First cancel all Flink jobs via REST API
        for query_name, job_id in self.session_state.job_ids.items():
            success = self._cancel_job(job_id)
            cancellation_results[query_name] = success

        # Close all operations via SQL Gateway
        for op_handle in self.session_state.operation_handles.values():
            self._close_operation(op_handle)

        # Close session
        try:
            self._http_json(
                "DELETE",
                urljoin(self.base_url, f"sessions/{self.session_state.session_handle}"),
            )
        except Exception:
            pass  # Best effort cleanup

        self.session_state = None
        return cancellation_results

    def _collect_job_ids_from_operations(self) -> None:
        """Fill missing job IDs by querying the operation status endpoints."""
        if not self.session_state:
            return
        
        for query_name, op_handle in self.session_state.operation_handles.items():
            if query_name in self.session_state.job_ids:
                continue
            
            job_id = self._fetch_job_id_for_operation(op_handle)
            if job_id:
                self.session_state.job_ids[query_name] = job_id

    def _fetch_job_id_for_operation(self, op_handle: str) -> Optional[str]:
        """Try to fetch the job ID for an operation from the SQL Gateway."""
        if not self.session_state:
            return None

        session_handle = self.session_state.session_handle
        # Try both status endpoints used by different Flink versions.
        status_paths = [
            f"sessions/{session_handle}/operations/{op_handle}",
            f"sessions/{session_handle}/operations/{op_handle}/status",
        ]

        for path in status_paths:
            try:
                payload = self._http_json("GET", urljoin(self.base_url, path))
                job_id = payload.get("jobId") or payload.get("jobID")
                if job_id:
                    return job_id
            except Exception:
                continue  # Best effort

        return None

    def _cancel_job(self, job_id: str) -> bool:
        """Cancel a Flink job via the Flink REST API.
        
        Returns True if cancellation was successful.
        """
        if not job_id:
            return False
        
        # Try multiple methods to cancel the job
        cancel_methods = [
            # Method 1: PATCH with mode=cancel (recommended Flink REST API)
            lambda: self.session.patch(
                f"{self.flink_rest_url}/jobs/{job_id}",
                params={"mode": "cancel"},
                timeout=self.timeout
            ),
            # Method 1b: PATCH with state=CANCELED (older REST API contract)
            lambda: self.session.patch(
                f"{self.flink_rest_url}/jobs/{job_id}",
                json={"state": "CANCELED"},
                timeout=self.timeout
            ),
            # Method 2: POST stop without drain (graceful stop)
            lambda: self.session.post(
                f"{self.flink_rest_url}/jobs/{job_id}/stop",
                params={"drain": "false"},
                timeout=self.timeout
            ),
            # Method 2: Direct cancel endpoint (older Flink versions)
            lambda: self.session.get(
                f"{self.flink_rest_url}/jobs/{job_id}/yarn-cancel",
                timeout=self.timeout
            ),
        ]
        
        for method in cancel_methods:
            try:
                resp = method()
                if resp.status_code < 400:
                    return True  # Success
            except Exception:
                continue  # Try next method

        # Fallback: try cancelling via SQL Gateway statement (works even without REST API)
        return self._cancel_job_via_sql(job_id)

    def _cancel_job_via_sql(self, job_id: str) -> bool:
        """Cancel a Flink job via SQL statement (CANCEL JOB) through the Gateway."""
        if not self.session_state or not self.base_url:
            return False

        try:
            cancel_sql = f"CANCEL JOB '{job_id}'"
            payload = self._http_json(
                "POST",
                urljoin(
                    self.base_url,
                    f"sessions/{self.session_state.session_handle}/statements",
                ),
                json_body={"statement": cancel_sql},
            )

            # Some gateways return operationHandle, others an immediate result.
            # If an operationHandle is returned, close it to avoid leakage.
            op_handle = (
                payload.get("operationHandle")
                or payload.get("operation_handle")
                or None
            )
            if op_handle:
                try:
                    self._close_operation(self._extract_handle(op_handle))
                except Exception:
                    pass

            # If we reached here, the request was accepted.
            return True
        except Exception:
            return False

    def configure_session(self, sql_statement: str) -> None:
        """Execute configuration SQL (e.g., USE CATALOG, USE DATABASE)."""
        if not self.session_state:
            raise FlinkClientError("Not connected. Call connect() first.")

        self._http_json(
            "POST",
            urljoin(
                self.base_url,
                f"sessions/{self.session_state.session_handle}/configure-session",
            ),
            json_body={"statement": sql_statement},
        )

    def execute_query(self, query_name: str, sql: str) -> str:
        """Execute SQL query and return operation handle."""
        if not self.session_state:
            raise FlinkClientError("Not connected. Call connect() first.")

        resp = self._http_json(
            "POST",
            urljoin(
                self.base_url,
                f"sessions/{self.session_state.session_handle}/statements",
            ),
            json_body={"statement": sql},
        )

        op_handle = self._extract_handle(
            resp.get("operationHandle") or resp.get("operation_handle") or resp
        )

        self.session_state.operation_handles[query_name] = op_handle
        return op_handle

    def poll_results(
        self, query_name: str, row_format: str = "JSON"
    ) -> Optional[QueryResult]:
        """Poll for new results from a streaming query."""
        if not self.session_state:
            raise FlinkClientError("Not connected. Call connect() first.")

        op_handle = self.session_state.operation_handles.get(query_name)
        if not op_handle:
            raise FlinkClientError(f"No operation handle found for query: {query_name}")

        # Get tracking dicts from session state
        next_uris = self.session_state.next_result_uris
        query_columns = self.session_state.query_columns
        
        if query_name in next_uris and next_uris[query_name]:
            # Use the stored next URI
            result_url = urljoin(self.base_url, next_uris[query_name].lstrip("/"))
        else:
            # First poll - start from 0
            result_url = urljoin(
                self.base_url,
                f"sessions/{self.session_state.session_handle}/operations/{op_handle}/result/0?rowFormat={row_format}",
            )

        try:
            payload = self._http_json("GET", result_url)

            result_type = payload.get("resultType", "")
            next_uri = payload.get("nextResultUri")
            
            # Store the next URI for the next poll
            if next_uri:
                next_uris[query_name] = next_uri

            if result_type == "NOT_READY":
                return None

            if result_type == "EOS":
                # End of stream - this might not happen for continuous queries
                return QueryResult(
                    columns=[], rows=[], result_type="EOS", job_id=payload.get("jobID")
                )

            if result_type != "PAYLOAD":
                return None

            # Extract results
            results = payload.get("results", {})
            columns = self._extract_columns(results)
            
            # Store columns from first response, reuse if empty in subsequent
            if columns:
                query_columns[query_name] = columns
            elif query_name in query_columns:
                columns = query_columns[query_name]
            
            data = results.get("data", [])

            # Convert data to FlinkResultRow objects
            rows = []
            if row_format == "JSON":
                for item in data:
                    if isinstance(item, dict):
                        rows.append(
                            FlinkResultRow(
                                kind=item.get("kind", "INSERT"),
                                fields=item.get("fields", []),
                            )
                        )
            else:
                # PLAIN_TEXT format
                for item in data:
                    if isinstance(item, list):
                        rows.append(FlinkResultRow(kind="INSERT", fields=item))
                    else:
                        rows.append(FlinkResultRow(kind="INSERT", fields=[item]))

            # Store job ID for later cancellation
            job_id = payload.get("jobID")
            if job_id:
                self.session_state.job_ids[query_name] = job_id

            return QueryResult(
                columns=columns,
                rows=rows,
                result_type="PAYLOAD",
                next_uri=next_uri,
                job_id=job_id,
            )

        except Exception as e:
            self.session_state.is_connected = False
            raise FlinkClientError(f"Failed to poll results for {query_name}: {e}")

    def apply_changelog_to_state(
        self,
        columns: List[str],
        state: Dict[Tuple[str, ...], List[str]],
        changes: List[FlinkResultRow],
        key_columns: List[str],
    ) -> int:
        """Apply changelog results to in-memory state."""
        if not changes or not key_columns:
            return 0

        mutations = 0
        column_indices = {col: i for i, col in enumerate(columns)}

        for change in changes:
            kind = change.kind.upper()
            fields = change.fields

            # Convert fields to string list
            row = [str(v) if v is not None else "" for v in fields]

            # Build key tuple
            key_parts = []
            for key_col in key_columns:
                idx = column_indices.get(key_col, -1)
                if idx >= 0 and idx < len(row):
                    key_parts.append(row[idx])
                else:
                    key_parts.append("")
            key = tuple(key_parts)

            if kind in ("INSERT", "UPDATE_AFTER"):
                state[key] = row
                mutations += 1
            elif kind == "DELETE":
                if key in state:
                    del state[key]
                    mutations += 1
            # Ignore UPDATE_BEFORE to avoid flickering

        return mutations

    def get_sorted_rows_from_state(
        self,
        columns: List[str],
        state: Dict[Tuple[str, ...], List[str]],
        order_by: Optional[str] = None,
        descending: bool = False,
        limit: int = 0,
    ) -> List[List[str]]:
        """Get sorted rows from state for display."""
        rows = list(state.values())

        if order_by and order_by in columns:
            col_idx = columns.index(order_by)

            def sort_key(row: List[str]) -> Any:
                if col_idx >= len(row):
                    return 0
                try:
                    # Try to parse as number for proper numeric sorting
                    return float(row[col_idx])
                except (ValueError, TypeError):
                    return row[col_idx]

            rows.sort(key=sort_key, reverse=descending)

        return rows[:limit] if limit > 0 else rows

    def _extract_handle(self, handle_obj: Any) -> str:
        """Extract handle string from response object."""
        if isinstance(handle_obj, str):
            return handle_obj
        if isinstance(handle_obj, dict) and "identifier" in handle_obj:
            return handle_obj["identifier"]
        raise FlinkClientError(f"Unexpected handle format: {handle_obj}")

    def _extract_columns(self, results: Dict[str, Any]) -> List[str]:
        """Extract column names from results."""
        if "columns" in results and isinstance(results["columns"], list):
            return [col.get("name", "") for col in results["columns"]]
        elif "resultSchema" in results and "columnNames" in results["resultSchema"]:
            return results["resultSchema"]["columnNames"]
        return []

    def _close_operation(self, op_handle: str) -> None:
        """Cancel and close a specific operation."""
        if not self.session_state:
            return
        
        session_handle = self.session_state.session_handle

        # Attempt to cancel the operation using the official PATCH endpoint first,
        # then fall back to the legacy /cancel path.
        cancel_attempts = [
            ("PATCH", f"sessions/{session_handle}/operations/{op_handle}", {"operationStatus": "CANCELED"}),
            ("POST", f"sessions/{session_handle}/operations/{op_handle}/cancel", None),
            # As a last resort, issue a CANCEL JOB statement if we can fetch a job ID.
        ]

        job_id_for_operation = None
        try:
            job_id_for_operation = self._fetch_job_id_for_operation(op_handle)
        except Exception:
            pass

        for method, path, json_body in cancel_attempts:
            try:
                resp = self.session.request(
                    method,
                    urljoin(self.base_url, path),
                    json=json_body if json_body else None,
                    timeout=self.timeout,
                )
                if resp.status_code < 400:
                    break
            except Exception:
                continue  # Try next method

        # If REST-style cancels failed and we have a job id, try CANCEL JOB via SQL.
        if job_id_for_operation:
            try:
                self._cancel_job_via_sql(job_id_for_operation)
            except Exception:
                pass

        # Then close the operation (ignore empty-body responses)
        try:
            resp = self.session.delete(
                urljoin(
                    self.base_url,
                    f"sessions/{session_handle}/operations/{op_handle}/close",
                ),
                timeout=self.timeout,
            )
            _ = resp.content  # consume for completeness; ignore body
        except Exception:
            pass  # Best effort cleanup

    def is_connected(self) -> bool:
        """Check if client is connected and session is active."""
        return self.session_state is not None and self.session_state.is_connected
