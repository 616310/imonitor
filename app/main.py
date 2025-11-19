import time
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import storage
from .config import PUBLIC_DIR, SCRIPTS_DIR, settings

app = FastAPI(title="iMonitor Central")

storage.init_db()


class ReserveRequest(BaseModel):
    label: Optional[str] = None


class ReportPayload(BaseModel):
    token: str
    hostname: str
    ip_address: Optional[str] = None
    meta: Dict[str, Any]
    metrics: Dict[str, Any]


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    index_file = PUBLIC_DIR / "index.html"
    if not index_file.exists():
        raise HTTPException(status_code=404, detail="UI not found")
    return HTMLResponse(index_file.read_text(encoding="utf-8"))


@app.get("/install.sh")
def install_script(request: Request) -> PlainTextResponse:
    script_path = SCRIPTS_DIR / "install.sh"
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Installer missing")
    base_url = str(request.base_url).rstrip("/")
    content = script_path.read_text(encoding="utf-8").replace("__DEFAULT_ENDPOINT__", base_url)
    return PlainTextResponse(content, media_type="text/x-shellscript")


@app.get("/agent.py")
def agent_script() -> FileResponse:
    script_path = SCRIPTS_DIR / "agent.py"
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Agent missing")
    return FileResponse(script_path, media_type="text/x-python", filename="agent.py")


@app.get("/api/nodes")
def api_nodes() -> Dict[str, Any]:
    nodes = storage.list_nodes()
    return {"nodes": nodes, "generated_at": time.time()}


@app.post("/api/nodes/reserve")
def api_reserve_node(req: ReserveRequest, request: Request) -> Dict[str, Any]:
    node = storage.create_node(label=req.label)
    base_url = str(request.base_url).rstrip("/")
    command = f"curl -fsSL {base_url}/install.sh | bash -s -- --token={node['token']} --endpoint={base_url}"
    return {"node_id": node["id"], "token": node["token"], "command": command}


@app.post("/api/report")
def api_report(payload: ReportPayload, request: Request) -> Dict[str, Any]:
    node = storage.get_node_by_token(payload.token)
    if not node:
        raise HTTPException(status_code=404, detail="Unknown token")

    ip_address = payload.ip_address or request.client.host
    storage.update_node_metrics(
        token=payload.token,
        hostname=payload.hostname,
        ip_address=ip_address,
        meta=payload.meta,
        metrics=payload.metrics,
    )
    return {"status": "ok"}


@app.delete("/api/nodes/{token}")
def api_delete_node(token: str) -> Dict[str, Any]:
    node = storage.get_node_by_token(token)
    if not node:
        raise HTTPException(status_code=404, detail="Unknown node")
    storage.delete_node(token)
    return {"status": "deleted"}


app.mount("/assets", StaticFiles(directory=PUBLIC_DIR), name="assets")
