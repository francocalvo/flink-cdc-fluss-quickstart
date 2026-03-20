#!/usr/bin/env python3
import argparse
import json
import os
import time
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urljoin

import requests


def clear_screen():
    os.system("clear")


def extract_handle(v: Any) -> str:
    if isinstance(v, str):
        return v
    if isinstance(v, dict) and "identifier" in v:
        return v["identifier"]
    raise ValueError(f"Unexpected handle: {v!r}")


def http_json(session: requests.Session, method: str, url: str, *, params=None, json_body=None, timeout=30) -> Dict[str, Any]:
    resp = session.request(method, url, params=params, json=json_body, timeout=timeout)
    if resp.status_code >= 400:
        try:
            j = resp.json()
            raise RuntimeError(f"HTTP {resp.status_code} {url}\n{json.dumps(j, indent=2, ensure_ascii=False)}")
        except Exception:
            raise RuntimeError(f"HTTP {resp.status_code} {url}\n{resp.text}")
    try:
        return resp.json()
    except Exception as e:
        raise RuntimeError(f"Non-JSON response from {url}: {e}\n{resp.text[:2000]}")


def pick_base_info_only(session: requests.Session, gateway: str, timeout: float) -> str:
    base = gateway.rstrip("/") + "/"
    _ = http_json(session, "GET", urljoin(base, "info"), timeout=timeout)  # validate
    return base


def open_session(session: requests.Session, base: str, timeout: float, properties: Optional[dict]) -> str:
    payload = {}
    if properties:
        payload["properties"] = properties
    j = http_json(session, "POST", urljoin(base, "sessions"), json_body=payload, timeout=timeout)
    return extract_handle(j.get("sessionHandle") or j.get("session_handle") or j)


def close_session(session: requests.Session, base: str, timeout: float, session_handle: str):
    try:
        http_json(session, "DELETE", urljoin(base, f"sessions/{session_handle}"), timeout=timeout)
    except Exception:
        pass


def close_operation(session: requests.Session, base: str, timeout: float, session_handle: str, op_handle: str):
    try:
        http_json(session, "DELETE", urljoin(base, f"sessions/{session_handle}/operations/{op_handle}/close"), timeout=timeout)
    except Exception:
        pass


def configure_session(session: requests.Session, base: str, timeout: float, session_handle: str, stmt: str):
    http_json(
        session,
        "POST",
        urljoin(base, f"sessions/{session_handle}/configure-session"),
        json_body={"statement": stmt},
        timeout=timeout,
    )


def execute_statement(session: requests.Session, base: str, timeout: float, session_handle: str, sql: str) -> str:
    j = http_json(
        session,
        "POST",
        urljoin(base, f"sessions/{session_handle}/statements"),
        json_body={"statement": sql},
        timeout=timeout,
    )
    return extract_handle(j.get("operationHandle") or j.get("operation_handle") or j)


def format_table(columns: List[str], rows: List[List[str]], max_width: int = 40) -> str:
    if not columns:
        return "(no columns)\n"

    def clip(s: str) -> str:
        s = ("" if s is None else str(s)).replace("\n", " ")
        return s if len(s) <= max_width else s[: max_width - 1] + "…"

    cols = [clip(c) for c in columns]
    rs = [[clip(v) for v in r] for r in rows]

    widths = [len(c) for c in cols]
    for r in rs:
        for i, v in enumerate(r[: len(cols)]):
            widths[i] = max(widths[i], len(v))

    def line(ch="-"):
        return "+" + "+".join(ch * (w + 2) for w in widths) + "+"

    out = [line("-")]
    out.append("| " + " | ".join(cols[i].ljust(widths[i]) for i in range(len(cols))) + " |")
    out.append(line("="))
    for r in rs:
        rr = (r[: len(cols)] + [""] * (len(cols) - len(r)))
        out.append("| " + " | ".join(rr[i].ljust(widths[i]) for i in range(len(cols))) + " |")
    out.append(line("-"))
    return "\n".join(out) + "\n"


# --- Update-aware in-memory table state (for JSON row format) ---

def row_key(columns: List[str], row: Dict[str, Any], key_cols: List[str]) -> Tuple[str, ...]:
    # row is typically {"kind":"INSERT","fields":[...]} OR sometimes {"kind":..., "fields":...}
    fields = row.get("fields") or []
    name_to_idx = {c: i for i, c in enumerate(columns)}
    key = []
    for kc in key_cols:
        idx = name_to_idx.get(kc)
        key.append("" if idx is None or idx >= len(fields) else str(fields[idx]))
    return tuple(key)


def apply_changes(
    columns: List[str],
    state: Dict[Tuple[str, ...], List[str]],
    changes: List[Dict[str, Any]],
    key_cols: List[str],
) -> int:
    """
    Apply changelog rows with kinds: INSERT/UPDATE_AFTER/UPDATE_BEFORE/DELETE.
    We keep the latest row per key.
    Returns number of state mutations.
    """
    muts = 0
    for ch in changes:
        kind = (ch.get("kind") or "").upper()
        fields = ch.get("fields") or []
        row = ["" if v is None else str(v) for v in fields]
        k = row_key(columns, ch, key_cols)

        if kind in ("INSERT", "UPDATE_AFTER"):
            state[k] = row
            muts += 1
        elif kind in ("DELETE", "UPDATE_BEFORE"):
            # In practice, UPDATE_BEFORE is followed by UPDATE_AFTER.
            # Removing on UPDATE_BEFORE can cause flicker; we can ignore UPDATE_BEFORE safely.
            if kind == "DELETE":
                if k in state:
                    del state[k]
                    muts += 1
        else:
            # Unknown kind → treat as upsert
            state[k] = row
            muts += 1
    return muts


def sorted_rows_from_state(
    columns: List[str],
    state: Dict[Tuple[str, ...], List[str]],
    order_by: Optional[str],
    desc: bool,
    limit: int,
) -> List[List[str]]:
    rows = list(state.values())
    if order_by and order_by in columns:
        idx = columns.index(order_by)
        def as_num(x: str):
            try:
                return float(x)
            except Exception:
                return x
        rows.sort(key=lambda r: as_num(r[idx]) if idx < len(r) else 0, reverse=desc)
    return rows[:limit] if limit > 0 else rows


def main():
    ap = argparse.ArgumentParser(description="Live query (Option B): execute once, keep polling, update console table.")
    ap.add_argument("--gateway", required=True, help="e.g. http://192.168.1.202:8083")
    ap.add_argument("--init-sql", action="append", default=[], help="Repeatable session init SQL")
    ap.add_argument("--sql", required=True, help="Query to run ONCE and keep reading results")
    ap.add_argument("--timeout", type=float, default=30.0, help="HTTP timeout seconds")
    ap.add_argument("--poll-ms", type=int, default=250, help="Poll interval when NOT_READY or no new rows")
    ap.add_argument("--render-ms", type=int, default=800, help="Min interval between screen renders")
    ap.add_argument("--row-format", choices=["JSON", "PLAIN_TEXT"], default="JSON",
                    help="JSON recommended for update-aware streaming results.")
    ap.add_argument("--key-cols", default="movie_id", help="Comma-separated key cols for upsert table (JSON mode).")
    ap.add_argument("--order-by", default="total_revenue", help="Column name to sort the live table by (client-side).")
    ap.add_argument("--desc", action="store_true", help="Sort descending (client-side).")
    ap.add_argument("--limit", type=int, default=10, help="Max rows to display (client-side).")
    ap.add_argument("--no-clear", action="store_true", help="Do not clear screen (append output).")
    args = ap.parse_args()

    s = requests.Session()
    base = pick_base_info_only(s, args.gateway, args.timeout)
    session_handle = open_session(s, base, args.timeout, properties=None)

    op_handle = None
    try:
        # init SQL (catalog/db/etc.)
        for stmt in args.init_sql:
            configure_session(s, base, args.timeout, session_handle, stmt)

        op_handle = execute_statement(s, base, args.timeout, session_handle, args.sql)

        # Start fetching. We must follow nextResultUri.
        next_url = urljoin(base, f"sessions/{session_handle}/operations/{op_handle}/result/0?rowFormat={args.row_format}")

        columns: List[str] = []
        state: Dict[Tuple[str, ...], List[str]] = {}
        key_cols = [c.strip() for c in args.key_cols.split(",") if c.strip()]

        last_render = 0.0
        total_events = 0

        while True:
            payload = http_json(s, "GET", next_url, timeout=args.timeout)
            rt = payload.get("resultType")

            next_uri = payload.get("nextResultUri")
            if next_uri:
                next_url = urljoin(base, next_uri.lstrip("/"))

            if rt == "NOT_READY":
                time.sleep(args.poll_ms / 1000.0)
                continue

            if rt == "EOS":
                # For a truly continuous query you may never see EOS.
                # If you do see it, we can stop.
                if not args.no_clear:
                    clear_screen()
                print("EOS reached. Done.")
                break

            if rt != "PAYLOAD":
                # Unexpected → print and back off
                if not args.no_clear:
                    clear_screen()
                print(json.dumps(payload, indent=2, ensure_ascii=False))
                time.sleep(args.poll_ms / 1000.0)
                continue

            results = payload.get("results") or {}
            data = results.get("data") or []

            # Extract column names once
            if not columns:
                if "columns" in results and isinstance(results["columns"], list):
                    columns = [c.get("name", "") for c in results["columns"]]
                elif "resultSchema" in results and "columnNames" in results["resultSchema"]:
                    columns = results["resultSchema"]["columnNames"]

            # Update table state
            changed = 0
            if args.row_format == "JSON":
                # Expect rows like {"kind":"INSERT","fields":[...]}
                if data:
                    changed = apply_changes(columns, state, data, key_cols)
                    total_events += len(data)
            else:
                # PLAIN_TEXT: append-only; no kind → just print what we got
                if data:
                    # Best-effort: map list rows into state by row index key
                    for i, r in enumerate(data):
                        if isinstance(r, list):
                            state[(str(i + len(state)),)] = ["" if v is None else str(v) for v in r]
                        else:
                            state[(str(i + len(state)),)] = [str(r)]
                    changed = len(data)
                    total_events += len(data)

            # Render only if something changed OR enough time elapsed
            now = time.time()
            should_render = (changed > 0) or (now - last_render) >= (args.render_ms / 1000.0)

            if should_render:
                if not args.no_clear:
                    clear_screen()

                display_rows = sorted_rows_from_state(
                    columns,
                    state,
                    order_by=args.order_by,
                    desc=args.desc,
                    limit=args.limit,
                )

                print(time.strftime("%Y-%m-%d %H:%M:%S"),
                      f"events={total_events} rows_in_state={len(state)} showing={len(display_rows)}")
                print(f"job/op: {payload.get('jobID','')} / {op_handle}")
                print()
                print(format_table(columns, display_rows))
                last_render = now

            # If no new rows, back off a bit to avoid hammering
            if changed == 0:
                time.sleep(args.poll_ms / 1000.0)

    except KeyboardInterrupt:
        print("\nInterrupted. Closing...")
    finally:
        if op_handle:
            close_operation(s, base, args.timeout, session_handle, op_handle)
        close_session(s, base, args.timeout, session_handle)


if __name__ == "__main__":
    main()

