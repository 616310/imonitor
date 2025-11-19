# iMonitor

Production-ready server resource monitor featuring a FastAPI backend, polished Vue/Tailwind UI, token-based agent onboarding, and automated install scripts.

## Components
- **FastAPI core** (`app/`) – Stores node metadata in SQLite, exposes REST endpoints for UI, agent registration, and metric ingestion.
- **Vue 3 UI** (`public/index.html`) – Modern glassmorphism dashboard showing CPU/RAM/disk, bandwidth, uptime, and per-node details.
- **Agent** (`scripts/agent.py`) – Lightweight Python metrics collector using psutil, reporting to the controller via HTTPS.
- **Installer** (`scripts/install.sh`) – One-command bootstrap that downloads the agent, writes env vars, and provisions a `systemd` service.

## Quick Start
```bash
cargo build --release
./target/release/imonitor
```

Visit `http://localhost:8080` to view the dashboard. Generate a token via “节点接入” and run the displayed command on any Linux server to enroll it.
