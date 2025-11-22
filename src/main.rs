use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    extract::{ConnectInfo, Multipart, Path as AxumPath, State},
    http::{header, HeaderMap, StatusCode},
    response::{Html, IntoResponse},
    routing::{delete, get, post},
    Json, Router,
};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use rand::Rng;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use thiserror::Error;
use tokio::{fs, net::TcpListener, signal, sync::RwLock};
use tower_http::services::ServeDir;
use tracing::{error, info};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use uuid::Uuid;

#[derive(Clone)]
struct Settings {
    public_url: String,
    offline_timeout: u64,
    bind_addr: String,
    admin_user: Option<String>,
    admin_pass: Option<String>,
}

#[derive(Clone)]
struct AppState {
    settings: Settings,
    public_dir: Arc<PathBuf>,
    scripts_dir: Arc<PathBuf>,
    data_dir: Arc<PathBuf>,
    app_settings: Arc<AppSettings>,
}

#[derive(Serialize)]
struct NodesResponse {
    nodes: Vec<NodeResponse>,
    generated_at: f64,
}

#[derive(Serialize)]
struct NodeResponse {
    id: String,
    label: Option<String>,
    hostname: Option<String>,
    ip_address: Option<String>,
    created_at: f64,
    last_seen: Option<f64>,
    status: String,
    token: String,
    meta: Option<Value>,
    metrics: Option<Value>,
}

struct NodeRaw {
    id: String,
    token: String,
    label: Option<String>,
    hostname: Option<String>,
    ip_address: Option<String>,
    created_at: f64,
    last_seen: Option<f64>,
    meta: Option<String>,
    metrics: Option<String>,
}

impl NodeRaw {
    fn into_response(self, offline_timeout: u64) -> Result<NodeResponse, AppError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();
        let status = match self.last_seen {
            Some(ts) if now - ts <= offline_timeout as f64 => "online".to_string(),
            Some(_) => "offline".to_string(),
            None => "pending".to_string(),
        };
        let meta_value = match self.meta {
            Some(ref m) => Some(serde_json::from_str(m).map_err(AppError::Serde)?),
            None => None,
        };
        let metrics_value = match self.metrics {
            Some(ref m) => Some(serde_json::from_str(m).map_err(AppError::Serde)?),
            None => None,
        };
        Ok(NodeResponse {
            id: self.id,
            token: self.token,
            label: self.label,
            hostname: self.hostname,
            ip_address: self.ip_address,
            created_at: self.created_at,
            last_seen: self.last_seen,
            status,
            meta: meta_value,
            metrics: metrics_value,
        })
    }
}

#[derive(Deserialize)]
struct ReserveRequest {
    label: Option<String>,
}

#[derive(Serialize)]
struct ReserveResponse {
    node_id: String,
    token: String,
    command: String,
}

#[derive(Deserialize)]
struct ReportPayload {
    token: String,
    hostname: String,
    #[serde(default)]
    ip_address: Option<String>,
    #[serde(default)]
    meta: Map<String, Value>,
    #[serde(default)]
    metrics: Map<String, Value>,
}

#[derive(Error, Debug)]
enum AppError {
    #[error("not found")]
    NotFound,
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("unauthorized")]
    Unauthorized,
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("bad request: {0}")]
    BadRequest(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        let status = match self {
            AppError::NotFound => StatusCode::NOT_FOUND,
            AppError::Unauthorized => StatusCode::UNAUTHORIZED,
            AppError::BadRequest(_) => StatusCode::BAD_REQUEST,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        };
        let body = Json(json!({"detail": self.to_string()}));
        (status, body).into_response()
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cwd = std::env::current_dir()?;
    let public_dir = cwd.join("public");
    let scripts_dir = cwd.join("scripts");
    let data_dir = cwd.join("data");
    if !data_dir.exists() {
        fs::create_dir_all(&data_dir).await?;
    }

    let settings = Settings {
        public_url: std::env::var("IMONITOR_PUBLIC_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:8080".into()),
        offline_timeout: std::env::var("IMONITOR_OFFLINE_TIMEOUT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(10),
        bind_addr: std::env::var("IMONITOR_BIND")
            .unwrap_or_else(|_| "[::]:8080".into()),
        admin_user: std::env::var("IMONITOR_ADMIN_USER").ok(),
        admin_pass: std::env::var("IMONITOR_ADMIN_PASS").ok(),
    };

    let app_settings = Arc::new(load_app_settings(&data_dir.join("settings.json"), &data_dir).await?);

    init_db(&data_dir.join("imonitor.db"))?;

    let state = AppState {
        settings,
        public_dir: Arc::new(public_dir),
        scripts_dir: Arc::new(scripts_dir),
        data_dir: Arc::new(data_dir),
        app_settings,
    };

    let app = Router::new()
        .route("/", get(index_handler))
        .route("/install.sh", get(install_script))
        .route("/agent.bin", get(agent_binary))
        .route("/ld-musl-x86_64.so.1", get(musl_loader))
        .route("/api/nodes", get(list_nodes_handler))
        .route("/api/nodes/reserve", post(reserve_node))
        .route("/api/login", post(login_handler))
        .route("/api/report", post(report_handler))
        .route("/api/nodes/:token", delete(delete_node_handler).patch(update_node_handler))
        .route("/api/settings", get(get_settings_handler))
        .route("/api/settings/background", post(update_background_handler))
        .route("/api/settings/background/upload", post(update_background_upload_handler))
        .route("/api/settings/background/file", get(get_background_file_handler))
        .nest_service("/assets", ServeDir::new(state.public_dir.as_ref()))
        .with_state(state.clone());

    let addr: SocketAddr = state
        .settings
        .bind_addr
        .parse()
        .unwrap_or_else(|_| "[::]:8080".parse().unwrap());
    info!("listening on {}", addr);
    let listener = TcpListener::bind(addr).await?;
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;

    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}

async fn index_handler(State(state): State<AppState>) -> Result<Html<String>, AppError> {
    let path = state.public_dir.join("index.html");
    let content = fs::read_to_string(path).await?;
    Ok(Html(content))
}

async fn install_script(State(state): State<AppState>) -> Result<impl IntoResponse, AppError> {
    let path = state.scripts_dir.join("install.sh");
    if !path.exists() {
        return Err(AppError::NotFound);
    }
    let mut content = fs::read_to_string(path).await?;
    content = content.replace("__DEFAULT_ENDPOINT__", &state.settings.public_url);
    let headers = [(header::CONTENT_TYPE, "text/x-shellscript")];
    Ok((headers, content))
}

async fn agent_binary(State(state): State<AppState>) -> Result<impl IntoResponse, AppError> {
    let path = state.scripts_dir.join("agent");
    if !path.exists() {
        return Err(AppError::NotFound);
    }
    let bytes = fs::read(path).await?;
    let headers = [(header::CONTENT_TYPE, "application/octet-stream")];
    Ok((headers, bytes))
}

async fn musl_loader(State(state): State<AppState>) -> Result<impl IntoResponse, AppError> {
    let path = state.scripts_dir.join("ld-musl-x86_64.so.1");
    if !path.exists() {
        return Err(AppError::NotFound);
    }
    let bytes = fs::read(path).await?;
    let headers = [(header::CONTENT_TYPE, "application/octet-stream")];
    Ok((headers, bytes))
}

async fn list_nodes_handler(
    State(state): State<AppState>,
) -> Result<Json<NodesResponse>, AppError> {
    let nodes = list_nodes(
        &state.data_dir.join("imonitor.db"),
        state.settings.offline_timeout,
    )?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    Ok(Json(NodesResponse {
        nodes,
        generated_at: now,
    }))
}

async fn reserve_node(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ReserveRequest>,
) -> Result<Json<ReserveResponse>, AppError> {
    require_auth(&headers, &state.settings)?;
    let result = create_node(
        &state.data_dir.join("imonitor.db"),
        payload.label.as_deref(),
    )?;
    let command = format!(
        "curl -fsSL {base}/install.sh | bash -s -- --token={token} --endpoint={base}",
        base = state.settings.public_url,
        token = result.token
    );
    Ok(Json(ReserveResponse {
        node_id: result.node_id,
        token: result.token,
        command,
    }))
}

async fn report_handler(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<ReportPayload>,
) -> Result<Json<Value>, AppError> {
    if payload.meta.is_empty() || payload.metrics.is_empty() {
        return Err(AppError::BadRequest("meta/metrics required".into()));
    }
    let client_ip = payload
        .ip_address
        .clone()
        .unwrap_or_else(|| addr.ip().to_string());
    update_node_metrics(
        &state.data_dir.join("imonitor.db"),
        &payload.token,
        &payload.hostname,
        &client_ip,
        &payload.meta,
        &payload.metrics,
    )?;
    Ok(Json(json!({"status": "ok"})))
}

async fn delete_node_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(token): AxumPath<String>,
) -> Result<Json<Value>, AppError> {
    require_auth(&headers, &state.settings)?;
    delete_node(&state.data_dir.join("imonitor.db"), &token)?;
    Ok(Json(json!({"status": "deleted"})))
}

#[derive(Deserialize)]
struct UpdateNodeRequest {
    label: Option<String>,
}

async fn update_node_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(token): AxumPath<String>,
    Json(payload): Json<UpdateNodeRequest>,
) -> Result<Json<Value>, AppError> {
    require_auth(&headers, &state.settings)?;
    update_node_label(&state.data_dir.join("imonitor.db"), &token, payload.label.as_deref())?;
    Ok(Json(json!({"status": "updated"})))
}

async fn login_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, AppError> {
    require_auth(&headers, &state.settings)?;
    Ok(Json(json!({"status": "ok"})))
}

struct NewNode {
    node_id: String,
    token: String,
}

fn init_db(db_path: &Path) -> Result<(), AppError> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS nodes (
            id TEXT PRIMARY KEY,
            token TEXT UNIQUE NOT NULL,
            label TEXT,
            hostname TEXT,
            ip_address TEXT,
            created_at REAL DEFAULT (strftime('%s','now')),
            last_seen REAL,
            meta TEXT,
            metrics TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_nodes_token ON nodes(token);
        ",
    )?;
    Ok(())
}

fn list_nodes(db_path: &Path, offline_timeout: u64) -> Result<Vec<NodeResponse>, AppError> {
    let conn = Connection::open(db_path)?;
    let mut stmt = conn.prepare("SELECT * FROM nodes ORDER BY created_at ASC")?;
    let rows = stmt.query_map([], |row| {
        Ok(NodeRaw {
            id: row.get("id")?,
            label: row.get("label")?,
            hostname: row.get("hostname")?,
            ip_address: row.get("ip_address")?,
            created_at: row.get("created_at")?,
            last_seen: row.get("last_seen")?,
            token: row.get("token")?,
            meta: row.get("meta")?,
            metrics: row.get("metrics")?,
        })
    })?;
    let mut result = Vec::new();
    for row in rows {
        result.push(row?.into_response(offline_timeout)?);
    }
    Ok(result)
}

fn create_node(db_path: &Path, label: Option<&str>) -> Result<NewNode, AppError> {
    let conn = Connection::open(db_path)?;
    let node_id = Uuid::new_v4().to_string();
    let token = generate_token();
    conn.execute(
        "INSERT INTO nodes (id, token, label, created_at) VALUES (?, ?, ?, strftime('%s','now'))",
        params![node_id, token, label],
    )?;
    Ok(NewNode { node_id, token })
}

fn update_node_metrics(
    db_path: &Path,
    token: &str,
    hostname: &str,
    ip_address: &str,
    meta: &Map<String, Value>,
    metrics: &Map<String, Value>,
) -> Result<(), AppError> {
    let conn = Connection::open(db_path)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    let meta_json = serde_json::to_string(meta)?;
    let metrics_json = serde_json::to_string(metrics)?;
    let rows = conn.execute(
        "UPDATE nodes SET hostname = COALESCE(?, hostname),
            label = CASE WHEN label IS NULL OR label = '' THEN ? ELSE label END,
            ip_address = ?,
            meta = ?,
            metrics = ?,
            last_seen = ?
        WHERE token = ?",
        params![
            hostname,
            hostname,
            ip_address,
            meta_json,
            metrics_json,
            now,
            token
        ],
    )?;
    if rows == 0 {
        return Err(AppError::NotFound);
    }
    // 清理同一主控下重复的节点（同 hostname 或 IP）
    if !hostname.is_empty() || !ip_address.is_empty() {
        conn.execute(
            "DELETE FROM nodes WHERE token != ? AND (
                (hostname IS NOT NULL AND hostname = ?)
                OR
                (ip_address IS NOT NULL AND ip_address = ?)
            )",
            params![token, hostname, ip_address],
        )?;
    }
    Ok(())
}

fn delete_node(db_path: &Path, token: &str) -> Result<(), AppError> {
    let conn = Connection::open(db_path)?;
    let rows = conn.execute("DELETE FROM nodes WHERE token = ?", params![token])?;
    if rows == 0 {
        return Err(AppError::NotFound);
    }
    Ok(())
}

fn update_node_label(db_path: &Path, token: &str, label: Option<&str>) -> Result<(), AppError> {
    let conn = Connection::open(db_path)?;
    let rows = conn.execute(
        "UPDATE nodes SET label = ? WHERE token = ?",
        params![label, token],
    )?;
    if rows == 0 {
        return Err(AppError::NotFound);
    }
    Ok(())
}

fn generate_token() -> String {
    let mut rng = rand::thread_rng();
    (0..40)
        .map(|_| format!("{:x}", rng.gen_range(0..16)))
        .collect()
}

fn auth_enabled(settings: &Settings) -> bool {
    settings.admin_user.is_some() && settings.admin_pass.is_some()
}

fn require_auth(headers: &HeaderMap, settings: &Settings) -> Result<(), AppError> {
    if !auth_enabled(settings) {
        return Ok(());
    }
    let auth = headers
        .get(header::AUTHORIZATION)
        .ok_or(AppError::Unauthorized)?
        .to_str()
        .map_err(|_| AppError::Unauthorized)?;
    if !auth.starts_with("Basic ") {
        return Err(AppError::Unauthorized);
    }
    let decoded = BASE64_STANDARD
        .decode(auth.trim_start_matches("Basic ").trim())
        .map_err(|_| AppError::Unauthorized)?;
    let creds = String::from_utf8(decoded).map_err(|_| AppError::Unauthorized)?;
    let (user, pass) = creds
        .split_once(':')
        .ok_or(AppError::Unauthorized)?;
    if settings.admin_user.as_deref() == Some(user) && settings.admin_pass.as_deref() == Some(pass) {
        Ok(())
    } else {
        Err(AppError::Unauthorized)
    }
}

#[derive(Serialize, Deserialize)]
struct PersistedSettings {
    background_url: Option<String>,
}

struct AppSettings {
    path: PathBuf,
    bg_file: PathBuf,
    background_url: RwLock<String>,
}

async fn load_app_settings(path: &Path, data_dir: &Path) -> Result<AppSettings, AppError> {
    let default_bg = "https://images.unsplash.com/photo-1496504175726-c7b4523c7e81?q=80&w=2617&auto=format&fit=crop".to_string();
    let data = if path.exists() {
        fs::read(path).await?
    } else {
        Vec::new()
    };
    let persisted: PersistedSettings = if data.is_empty() {
        PersistedSettings {
            background_url: Some(default_bg.clone()),
        }
    } else {
        serde_json::from_slice(&data).map_err(AppError::Serde)?
    };
    Ok(AppSettings {
        path: path.to_path_buf(),
        bg_file: data_dir.join("background_upload.bin"),
        background_url: RwLock::new(
            persisted
                .background_url
                .unwrap_or_else(|| default_bg.clone()),
        ),
    })
}

async fn save_app_settings(app_settings: &AppSettings) -> Result<(), AppError> {
    let bg = app_settings.background_url.read().await.clone();
    let payload = PersistedSettings {
        background_url: Some(bg),
    };
    let bytes = serde_json::to_vec_pretty(&payload)?;
    fs::write(&app_settings.path, bytes).await?;
    Ok(())
}

async fn get_settings_handler(State(state): State<AppState>) -> Result<Json<Value>, AppError> {
    let bg = state.app_settings.background_url.read().await.clone();
    Ok(Json(json!({ "background_url": bg })))
}

#[derive(Deserialize)]
struct UpdateBackgroundRequest {
    background_url: String,
}

async fn update_background_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<UpdateBackgroundRequest>,
) -> Result<Json<Value>, AppError> {
    require_auth(&headers, &state.settings)?;
    {
        let mut bg = state.app_settings.background_url.write().await;
        *bg = payload.background_url.clone();
    }
    save_app_settings(&state.app_settings).await?;
    Ok(Json(json!({"status": "updated"})))
}

async fn update_background_upload_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Result<Json<Value>, AppError> {
    require_auth(&headers, &state.settings)?;
    let mut saved = false;
    while let Some(field) = multipart.next_field().await.map_err(|_| AppError::BadRequest("invalid multipart".into()))? {
        let name = field.name().unwrap_or("").to_string();
        if name != "file" {
            continue;
        }
        let data = field.bytes().await.map_err(|_| AppError::BadRequest("invalid file".into()))?;
        fs::write(&state.app_settings.bg_file, &data).await?;
        {
            let mut bg = state.app_settings.background_url.write().await;
            *bg = "/api/settings/background/file".to_string();
        }
        save_app_settings(&state.app_settings).await?;
        saved = true;
        break;
    }
    if !saved {
        return Err(AppError::BadRequest("file is required".into()));
    }
    Ok(Json(json!({"status": "updated", "background_url": "/api/settings/background/file"})))
}

async fn get_background_file_handler(State(state): State<AppState>) -> Result<(HeaderMap, Vec<u8>), AppError> {
    if !state.app_settings.bg_file.exists() {
        return Err(AppError::NotFound);
    }
    let data = fs::read(&state.app_settings.bg_file).await?;
    let mime = mime_guess::from_path(&state.app_settings.bg_file).first_or_octet_stream();
    let mut headers = HeaderMap::new();
    headers.insert(header::CONTENT_TYPE, header::HeaderValue::from_str(mime.as_ref()).unwrap_or(header::HeaderValue::from_static("application/octet-stream")));
    Ok((headers, data))
}
