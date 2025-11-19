import json
import secrets
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from .config import DB_PATH, settings


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                token TEXT UNIQUE NOT NULL,
                label TEXT,
                hostname TEXT,
                ip_address TEXT,
                created_at REAL DEFAULT (strftime('%s','now')),
                last_seen REAL,
                meta TEXT,
                metrics TEXT
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_nodes_token ON nodes(token)"
        )
        conn.commit()


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    meta = json.loads(row["meta"]) if row["meta"] else None
    metrics = json.loads(row["metrics"]) if row["metrics"] else None
    offline_timeout = settings.offline_timeout
    now = time.time()
    if row["last_seen"] is None:
        status = "pending"
    else:
        status = "online" if now - row["last_seen"] <= offline_timeout else "offline"

    return {
        "id": row["id"],
        "label": row["label"],
        "hostname": row["hostname"],
        "ip_address": row["ip_address"],
        "created_at": row["created_at"],
        "last_seen": row["last_seen"],
        "status": status,
        "meta": meta,
        "metrics": metrics,
    }


def list_nodes() -> List[Dict[str, Any]]:
    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM nodes ORDER BY created_at ASC").fetchall()
    return [_row_to_dict(row) for row in rows]


def create_node(label: Optional[str] = None, token: Optional[str] = None) -> Dict[str, Any]:
    node_id = str(uuid.uuid4())
    node_token = token or secrets.token_hex(20)
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO nodes (id, token, label, created_at) VALUES (?, ?, ?, strftime('%s','now'))",
            (node_id, node_token, label),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM nodes WHERE id = ?", (node_id,)).fetchone()
    return _row_to_dict(row) | {"token": node_token}


def get_node_by_token(token: str) -> Optional[Dict[str, Any]]:
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM nodes WHERE token = ?", (token,)).fetchone()
    if not row:
        return None
    return _row_to_dict(row)


def update_node_metrics(
    *,
    token: str,
    hostname: Optional[str],
    ip_address: Optional[str],
    meta: Dict[str, Any],
    metrics: Dict[str, Any],
) -> None:
    payload_meta = json.dumps(meta, ensure_ascii=False)
    payload_metrics = json.dumps(metrics, ensure_ascii=False)
    now = time.time()

    with get_conn() as conn:
        conn.execute(
            """
            UPDATE nodes
            SET hostname = COALESCE(?, hostname),
                label = CASE WHEN label IS NULL OR label = '' THEN ? ELSE label END,
                ip_address = ?,
                meta = ?,
                metrics = ?,
                last_seen = ?
            WHERE token = ?
            """,
            (
                hostname,
                hostname,
                ip_address,
                payload_meta,
                payload_metrics,
                now,
                token,
            ),
        )
        conn.commit()


def delete_node(token: str) -> None:
    with get_conn() as conn:
        conn.execute("DELETE FROM nodes WHERE token = ?", (token,))
        conn.commit()
