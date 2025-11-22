# iMonitor

Production-ready server resource monitor with an Axum (Rust) backend, Vue/Tailwind UI, token-based Rust agent, and automated install scripts.

## Components
- **Control panel** (`src/main.rs`) – Axum + SQLite; serves static UI, node listing, token issuance, and metric ingestion.
- **Vue 3 UI** (`public/index.html`) – Glass dashboard for CPU/RAM/disk, bandwidth, uptime, load, and per-node details.
- **Agent** (`scripts/agent`) – Static Rust binary reading `/proc` and filesystem; no Python/runtime required, defaults to 5s interval.
- **Panel installer** (`scripts/install-panel.sh`) – Root-only script that copies the build, writes `imonitor-lite` systemd, and prints the access URL/admin credentials.
- **Agent installer** (`scripts/install.sh`) – Downloads the agent and musl loader (if missing), writes `imonitor-agent` systemd on the target node.
- **CLI (`i-mo`)** – Operations only (status/logs/start/stop/restart/config view/uninstall); installation is handled by the scripts above.

## Quick server setup (single script)
```bash
curl -fsSL https://raw.githubusercontent.com/616310/imonitor/main/scripts/install-panel.sh | sudo bash
```
The script auto-clones the repo, copies the build to `/opt/imonitor-lite`, creates the `imonitor-lite` systemd service, starts it, and prints the access URL/admin credentials. The service listens on `[::]:8080` by default; align `IMONITOR_PUBLIC_URL` with your reverse proxy/HTTPS domain when prompted.
Key env vars: `IMONITOR_BIND` (default `[::]:8080`), `IMONITOR_PUBLIC_URL` (with http/https), `IMONITOR_OFFLINE_TIMEOUT` (default 10s).

## Quick Start
```bash
cargo build --release
./target/release/imonitor
```

Visit `http://localhost:8080` to view the dashboard. Generate a token via “节点接入” and run the displayed command on any Linux server to enroll it.
