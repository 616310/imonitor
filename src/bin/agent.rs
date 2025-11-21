use libc::statvfs;
use reqwest::{blocking::Client, Url};
use serde_json::{json, Map, Value};
use std::{
    env,
    ffi::CStr,
    fs::File,
    io::{BufRead, BufReader},
    net::UdpSocket,
    os::raw::c_char,
    process,
    thread,
    time::{Duration, Instant},
};

const DEFAULT_INTERVAL: u64 = 5;
const DEFAULT_FLAG: &str = "🖥️";

struct Config {
    token: String,
    endpoint: String,
    interval: u64,
    flag: String,
}

#[derive(Clone, Copy)]
struct CpuTimes {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,
    steal: u64,
}

fn main() {
    let cfg = match load_config() {
        Ok(cfg) => cfg,
        Err(err) => {
            eprintln!("[agent] {err}");
            process::exit(1);
        }
    };

    let report_url = Url::parse(&format!(
        "{}/api/report",
        cfg.endpoint.trim_end_matches('/')
    ))
    .unwrap_or_else(|e| {
        eprintln!("[agent] invalid endpoint URL: {e}");
        process::exit(1);
    });

    let client = Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap_or_else(|e| {
            eprintln!("[agent] failed to build http client: {e}");
            process::exit(1);
        });

    let hostname = get_hostname();
    let ip_cache = detect_ip();
    let (os_short, os_full) = read_os_info();
    let (cpu_model, cpu_cores) = read_cpu_info();

    let mut prev_cpu = read_cpu_times();
    let mut prev_net = read_net_bytes().unwrap_or((0, 0));

    loop {
        let start = Instant::now();

        let cpu_usage = {
            let current = read_cpu_times();
            let usage = match (prev_cpu, current) {
                (Some(prev), Some(curr)) => compute_cpu_usage(prev, curr),
                _ => 0.0,
            };
            prev_cpu = current;
            usage
        };

        let (mem_total, mem_available) = read_meminfo().unwrap_or((0, 0));
        let memory_percent = if mem_total > 0 {
            let used = mem_total.saturating_sub(mem_available);
            (used as f64 / mem_total as f64) * 100.0
        } else {
            0.0
        };

        let disk_percent = read_disk_percent().unwrap_or(0.0);
        let load_avg = read_loadavg().unwrap_or([0.0, 0.0, 0.0]);
        let uptime = read_uptime().unwrap_or(0);

        let net = read_net_bytes().unwrap_or((0, 0));
        let delta_sent = net.0.saturating_sub(prev_net.0);
        let delta_recv = net.1.saturating_sub(prev_net.1);
        prev_net = net;
        let sent_speed = bytes_per_sec_to_mb(delta_sent, cfg.interval);
        let recv_speed = bytes_per_sec_to_mb(delta_recv, cfg.interval);

        let mut meta = Map::new();
        meta.insert("os".into(), json!(os_short.clone()));
        meta.insert("os_short".into(), json!(os_short.clone()));
        meta.insert("os_full".into(), json!(os_full.clone()));
        meta.insert("arch".into(), json!(env::consts::ARCH));
        meta.insert("cpu_model".into(), json!(cpu_model.clone()));
        meta.insert("cpu_cores".into(), json!(cpu_cores));
        meta.insert("flag".into(), json!(cfg.flag.clone()));

        let mut metrics = Map::new();
        metrics.insert("cpu".into(), json!(round2(cpu_usage)));
        metrics.insert("memory_percent".into(), json!(round2(memory_percent)));
        metrics.insert("disk_percent".into(), json!(round2(disk_percent)));
        metrics.insert("net_sent_speed".into(), json!(round3(sent_speed)));
        metrics.insert("net_recv_speed".into(), json!(round3(recv_speed)));
        metrics.insert(
            "total_sent".into(),
            json!(round3(bytes_to_gb(net.0))),
        );
        metrics.insert(
            "total_recv".into(),
            json!(round3(bytes_to_gb(net.1))),
        );
        metrics.insert(
            "load_avg".into(),
            json!(vec![
                round2(load_avg[0]),
                round2(load_avg[1]),
                round2(load_avg[2])
            ]),
        );
        metrics.insert("uptime".into(), json!(uptime));

        let payload = json!({
            "token": cfg.token,
            "hostname": hostname,
            "ip_address": ip_cache,
            "meta": Value::Object(meta),
            "metrics": Value::Object(metrics),
        });

        match client.post(report_url.clone()).json(&payload).send() {
            Ok(resp) => {
                if !resp.status().is_success() {
                    eprintln!(
                        "[agent] server rejected payload: {} {}",
                        resp.status(),
                        resp.text().unwrap_or_default()
                    );
                }
            }
            Err(err) => eprintln!("[agent] failed to push metrics: {err}"),
        }

        let elapsed = start.elapsed();
        if elapsed < Duration::from_secs(cfg.interval) {
            thread::sleep(Duration::from_secs(cfg.interval) - elapsed);
        }
    }
}

fn load_config() -> Result<Config, String> {
    let mut token = env::var("IMONITOR_TOKEN").ok();
    let mut endpoint = env::var("IMONITOR_ENDPOINT").ok();
    let mut interval = env::var("IMONITOR_INTERVAL")
        .ok()
        .and_then(|v| v.parse::<u64>().ok());
    let mut flag = env::var("IMONITOR_FLAG").ok();

    let mut args = env::args().skip(1).peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--token" => {
                if let Some(val) = args.next() {
                    token = Some(val);
                }
            }
            "--endpoint" => {
                if let Some(val) = args.next() {
                    endpoint = Some(val);
                }
            }
            "--interval" => {
                if let Some(val) = args.next() {
                    interval = val.parse::<u64>().ok();
                }
            }
            "--flag" => {
                if let Some(val) = args.next() {
                    flag = Some(val);
                }
            }
            _ => {
                if let Some(val) = arg.strip_prefix("--token=") {
                    token = Some(val.to_string());
                } else if let Some(val) = arg.strip_prefix("--endpoint=") {
                    endpoint = Some(val.to_string());
                } else if let Some(val) = arg.strip_prefix("--interval=") {
                    interval = val.parse::<u64>().ok();
                } else if let Some(val) = arg.strip_prefix("--flag=") {
                    flag = Some(val.to_string());
                }
            }
        }
    }

    let token = token.ok_or_else(|| "missing --token".to_string())?;
    let endpoint = endpoint.ok_or_else(|| "missing --endpoint".to_string())?;
    let interval = interval.unwrap_or(DEFAULT_INTERVAL).max(1);
    let flag = flag.unwrap_or_else(|| DEFAULT_FLAG.to_string());

    Ok(Config {
        token,
        endpoint,
        interval,
        flag,
    })
}

fn detect_ip() -> String {
    if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
        if sock.connect("8.8.8.8:80").is_ok() {
            if let Ok(addr) = sock.local_addr() {
                return addr.ip().to_string();
            }
        }
    }
    String::new()
}

fn get_hostname() -> String {
    unsafe {
        let mut buf = [0u8; 256];
        if libc::gethostname(buf.as_mut_ptr() as *mut c_char, buf.len()) == 0 {
            if let Ok(cstr) = CStr::from_ptr(buf.as_ptr() as *const c_char).to_str() {
                return cstr.trim_end_matches(char::from(0)).to_string();
            }
        }
    }
    "unknown".to_string()
}

fn read_cpu_times() -> Option<CpuTimes> {
    let file = File::open("/proc/stat").ok()?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    if parts.next()? != "cpu" {
        return None;
    }
    let nums: Vec<u64> = parts.filter_map(|p| p.parse::<u64>().ok()).collect();
    if nums.len() < 8 {
        return None;
    }
    Some(CpuTimes {
        user: nums[0],
        nice: nums[1],
        system: nums[2],
        idle: nums[3],
        iowait: nums.get(4).copied().unwrap_or(0),
        irq: nums.get(5).copied().unwrap_or(0),
        softirq: nums.get(6).copied().unwrap_or(0),
        steal: nums.get(7).copied().unwrap_or(0),
    })
}

fn compute_cpu_usage(prev: CpuTimes, curr: CpuTimes) -> f64 {
    let prev_idle = prev.idle + prev.iowait;
    let curr_idle = curr.idle + curr.iowait;
    let prev_total = prev_idle + prev.user + prev.nice + prev.system + prev.irq + prev.softirq + prev.steal;
    let curr_total = curr_idle + curr.user + curr.nice + curr.system + curr.irq + curr.softirq + curr.steal;
    let totald = curr_total.saturating_sub(prev_total) as f64;
    let idled = curr_idle.saturating_sub(prev_idle) as f64;
    if totald <= 0.0 {
        0.0
    } else {
        (1.0 - idled / totald) * 100.0
    }
}

fn read_meminfo() -> Option<(u64, u64)> {
    let file = File::open("/proc/meminfo").ok()?;
    let reader = BufReader::new(file);
    let mut total = 0;
    let mut available = 0;
    for line in reader.lines().flatten() {
        if line.starts_with("MemTotal:") {
            total = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
        } else if line.starts_with("MemAvailable:") {
            available = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
        }
        if total > 0 && available > 0 {
            break;
        }
    }
    if total == 0 {
        None
    } else {
        // values are in kB
        Some((total * 1024, available * 1024))
    }
}

fn read_disk_percent() -> Option<f64> {
    unsafe {
        let mut vfs: statvfs = std::mem::zeroed();
        if statvfs(b"/\0".as_ptr() as *const c_char, &mut vfs) != 0 {
            return None;
        }
        let blocks = vfs.f_blocks as f64;
        if blocks <= 0.0 {
            return None;
        }
        let free = vfs.f_bavail as f64;
        let used = blocks - free;
        Some((used / blocks) * 100.0)
    }
}

fn read_net_bytes() -> Option<(u64, u64)> {
    let file = File::open("/proc/net/dev").ok()?;
    let reader = BufReader::new(file);
    let mut sent = 0u64;
    let mut recv = 0u64;
    for line in reader.lines().flatten().skip(2) {
        if let Some((iface, data)) = line.split_once(':') {
            let iface = iface.trim();
            if iface.is_empty() {
                continue;
            }
            let fields: Vec<&str> = data.split_whitespace().collect();
            if fields.len() < 9 {
                continue;
            }
            let r: u64 = fields[0].parse().unwrap_or(0);
            let t: u64 = fields[8].parse().unwrap_or(0);
            recv = recv.saturating_add(r);
            sent = sent.saturating_add(t);
        }
    }
    Some((sent, recv))
}

fn read_loadavg() -> Option<[f64; 3]> {
    let mut line = String::new();
    let mut file = File::open("/proc/loadavg").ok()?;
    use std::io::Read;
    file.read_to_string(&mut line).ok()?;
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 3 {
        return None;
    }
    let one = parts[0].parse::<f64>().ok()?;
    let five = parts[1].parse::<f64>().ok()?;
    let fifteen = parts[2].parse::<f64>().ok()?;
    Some([one, five, fifteen])
}

fn read_uptime() -> Option<u64> {
    let mut line = String::new();
    let mut file = File::open("/proc/uptime").ok()?;
    use std::io::Read;
    file.read_to_string(&mut line).ok()?;
    let first = line.split_whitespace().next()?;
    first.parse::<f64>().ok().map(|v| v as u64)
}

fn read_os_info() -> (String, String) {
    let mut pretty = String::new();
    let mut name = String::new();
    let mut version = String::new();
    if let Ok(file) = File::open("/etc/os-release") {
        for line in BufReader::new(file).lines().flatten() {
            if line.starts_with("PRETTY_NAME=") {
                pretty = line.trim_start_matches("PRETTY_NAME=").trim_matches('"').to_string();
            } else if line.starts_with("NAME=") && name.is_empty() {
                name = line.trim_start_matches("NAME=").trim_matches('"').to_string();
            } else if line.starts_with("VERSION=") && version.is_empty() {
                version = line.trim_start_matches("VERSION=").trim_matches('"').to_string();
            }
        }
    }
    let os_short = if !pretty.is_empty() {
        pretty.clone()
    } else if !name.is_empty() {
        if !version.is_empty() {
            format!("{name} {version}")
        } else {
            name.clone()
        }
    } else {
        "Linux".to_string()
    };
    let os_full = if !pretty.is_empty() {
        pretty
    } else {
        os_short.clone()
    };
    (os_short, os_full)
}

fn read_cpu_info() -> (String, u64) {
    let file = File::open("/proc/cpuinfo");
    if let Ok(file) = file {
        let mut model = "Unknown CPU".to_string();
        let mut cores = 0u64;
        let mut hypervisor = false;
        let mut hyper_vendor = String::new();
        for line in BufReader::new(file).lines().flatten() {
            if line.starts_with("model name") && model == "Unknown CPU" {
                if let Some(val) = line.split(':').nth(1) {
                    model = val.trim().to_string();
                }
            } else if line.starts_with("flags") && line.contains("hypervisor") {
                hypervisor = true;
            } else if line.starts_with("processor") {
                cores += 1;
            } else if line.starts_with("Hypervisor vendor") {
                if let Some(val) = line.split(':').nth(1) {
                    hyper_vendor = val.trim().to_string();
                }
            }
        }
        if cores == 0 {
            cores = 1;
        }
        if hypervisor {
            let mut label = "虚拟 CPU".to_string();
            if !hyper_vendor.is_empty() {
                label.push_str(&format!(" ({})", hyper_vendor));
            } else {
                label.push_str(&format!(" / {}", model));
            }
            model = label;
        }
        return (model, cores);
    }
    ("Unknown CPU".to_string(), 1)
}

fn bytes_per_sec_to_mb(bytes: u64, interval_sec: u64) -> f64 {
    if interval_sec == 0 {
        return 0.0;
    }
    let per_sec = bytes as f64 / interval_sec as f64;
    per_sec / (1024.0 * 1024.0)
}

fn bytes_to_gb(bytes: u64) -> f64 {
    bytes as f64 / (1024.0 * 1024.0 * 1024.0)
}

fn round2(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}
