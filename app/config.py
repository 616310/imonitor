import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
PUBLIC_DIR = BASE_DIR / "public"
SCRIPTS_DIR = BASE_DIR / "scripts"
DB_PATH = DATA_DIR / "imonitor.db"

DATA_DIR.mkdir(parents=True, exist_ok=True)

class Settings:
    def __init__(self) -> None:
        self.public_url = os.environ.get("IMONITOR_PUBLIC_URL", "http://127.0.0.1:8080")
        self.agent_poll_interval = int(os.environ.get("IMONITOR_AGENT_INTERVAL", "5"))
        self.offline_timeout = int(os.environ.get("IMONITOR_OFFLINE_TIMEOUT", "30"))

settings = Settings()
