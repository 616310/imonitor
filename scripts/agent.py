#!/usr/bin/env python3
"""iMonitor Agent - collects system metrics and reports to the central server."""

import argparse
import json
import os
import platform
import socket
import sys
import time
from typing import List

import psutil
import requests


def detect_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return ""


def cpu_model_name() -> str:
    if platform.system() == "Linux":
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8") as fh:
                for line in fh:
                    if "model name" in line:
                        return line.split(":", 1)[1].strip()
        except FileNotFoundError:
            pass
    return platform.processor() or "Unknown CPU"


def get_load_avg() -> List[float]:
    try:
        loads = os.getloadavg()
        return [round(val, 2) for val in loads]
    except (AttributeError, OSError):
        return [0.0, 0.0, 0.0]


def main() -> None:
    parser = argparse.ArgumentParser(description="iMonitor Agent")
    parser.add_argument("--token", default=os.environ.get("IMONITOR_TOKEN"))
    parser.add_argument("--endpoint", default=os.environ.get("IMONITOR_ENDPOINT"))
    parser.add_argument("--interval", type=int, default=int(os.environ.get("IMONITOR_INTERVAL", "5")))
    parser.add_argument("--flag", default=os.environ.get("IMONITOR_FLAG", "🖥️"))
    args = parser.parse_args()

    if not args.token or not args.endpoint:
        print("[agent] Missing --token or --endpoint", file=sys.stderr)
        sys.exit(1)

    endpoint = args.endpoint.rstrip("/")
    report_url = f"{endpoint}/api/report"

    hostname = platform.node()
    meta = {
        "os": platform.system(),
        "os_short": f"{platform.system()} {platform.release()}",
        "os_full": platform.platform(),
        "arch": platform.machine(),
        "cpu_model": cpu_model_name(),
        "cpu_cores": psutil.cpu_count(logical=False) or psutil.cpu_count(),
        "flag": args.flag,
    }

    prev_net = psutil.net_io_counters()
    prev_sent = prev_net.bytes_sent
    prev_recv = prev_net.bytes_recv
    ip_cache = detect_ip()

    while True:
        cpu_usage = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage("/")
        net = psutil.net_io_counters()
        uptime = int(time.time() - psutil.boot_time())

        delta_sent = max(net.bytes_sent - prev_sent, 0)
        delta_recv = max(net.bytes_recv - prev_recv, 0)
        sent_speed = delta_sent / args.interval / (1024 * 1024)
        recv_speed = delta_recv / args.interval / (1024 * 1024)
        prev_sent = net.bytes_sent
        prev_recv = net.bytes_recv

        metrics = {
            "cpu": round(cpu_usage, 2),
            "memory_percent": round(mem.percent, 2),
            "disk_percent": round(disk.percent, 2),
            "net_sent_speed": round(sent_speed, 3),
            "net_recv_speed": round(recv_speed, 3),
            "total_sent": round(net.bytes_sent / (1024 ** 3), 3),
            "total_recv": round(net.bytes_recv / (1024 ** 3), 3),
            "load_avg": get_load_avg(),
            "uptime": uptime,
        }

        payload = {
            "token": args.token,
            "hostname": hostname,
            "ip_address": ip_cache,
            "meta": meta,
            "metrics": metrics,
        }

        try:
            resp = requests.post(report_url, json=payload, timeout=10)
            if resp.status_code >= 400:
                print(f"[agent] Server rejected payload: {resp.status_code} {resp.text}")
        except requests.RequestException as exc:
            print(f"[agent] Failed to push metrics: {exc}", file=sys.stderr)

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
