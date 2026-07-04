#!/usr/bin/env python3

import argparse
import ipaddress
import os
import re
import tempfile
from pathlib import Path


UNKNOWN = "unknown"
REPO_ROOT = Path(__file__).resolve().parents[2]
PROMPT_PATH = REPO_ROOT / "prompts" / "host-prioritization.txt"


SCAN_REPORT_RE = re.compile(r"^Nmap scan report for (.+)$")
HOST_UP_RE = re.compile(r"^Host is up(?: \(([^)]+?)(?: latency)?\))?\.$")
MAC_RE = re.compile(r"^MAC Address: ([0-9A-Fa-f:]{17})(?: \((.*)\))?$")


VENDOR_RULES = [
    ("eero", "eero", "network-infrastructure"),
    ("raspberry pi", "Raspberry Pi Foundation", "server"),
    ("canon", "Canon", "printer-scanner"),
    ("hewlett-packard", "Hewlett-Packard", "printer-scanner"),
    ("hp inc", "Hewlett-Packard", "printer-scanner"),
    (" hp ", "Hewlett-Packard", "printer-scanner"),
    ("apple", "Apple", "workstation"),
    ("belkin", "Belkin International", "smart-home-device"),
    ("lumi united", "Lumi United Technology", "smart-home-hub"),
    ("lifi labs", "LIFX", "smart-home-device"),
    ("gl technologies", "GL.iNet", "network-infrastructure"),
    ("gl.inet", "GL.iNet", "network-infrastructure"),
    ("d&m holdings", "D&M Holdings", "media-device"),
    ("samsung", "Samsung Electronics", "unknown-client"),
    ("nintendo", None, "game-console"),
    ("sony interactive entertainment", None, "game-console"),
    ("microsoft xbox", None, "game-console"),
    ("synology", None, "storage-nas"),
    ("qnap", None, "storage-nas"),
    ("asustor", None, "storage-nas"),
    ("western digital", None, "storage-nas"),
    ("ubiquiti", None, "network-infrastructure"),
    ("tp-link", None, "network-infrastructure"),
    ("tplink", None, "network-infrastructure"),
    ("netgear", None, "network-infrastructure"),
    ("cisco", None, "network-infrastructure"),
    ("aruba", None, "network-infrastructure"),
    ("mikrotik", None, "network-infrastructure"),
    ("ring", None, "camera"),
    ("wyze", None, "camera"),
    ("arlo", None, "camera"),
    ("hikvision", None, "camera"),
    ("dahua", None, "camera"),
    ("axis", None, "camera"),
]


def is_ip(value):
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def parse_scan_report_target(target):
    target = target.strip()

    match = re.match(r"^(.*) \(([^()]+)\)$", target)
    if match:
        hostname = match.group(1).strip() or UNKNOWN
        ip = match.group(2).strip()
        return ip, hostname

    if is_ip(target):
        return target, UNKNOWN

    return target, target


def get_host(hosts, order, ip):
    if ip not in hosts:
        hosts[ip] = {
            "ip": ip,
            "status": UNKNOWN,
            "latency": UNKNOWN,
            "mac": UNKNOWN,
            "vendor": UNKNOWN,
            "hostname": UNKNOWN,
        }
        order.append(ip)
    return hosts[ip]


def value_after_colon(line):
    return line.split(":", 1)[1].strip()


def clean_manufacturer(vendor):
    vendor = (vendor or "").strip()
    if not vendor or vendor.lower() == UNKNOWN:
        return UNKNOWN

    return vendor


def derive_manufacturer_and_type(vendor):
    manufacturer = clean_manufacturer(vendor)
    if manufacturer == UNKNOWN:
        return UNKNOWN, "unknown-client"

    normalized = f" {manufacturer.lower()} "

    for needle, mapped_manufacturer, probable_type in VENDOR_RULES:
        if needle in normalized:
            return mapped_manufacturer or manufacturer, probable_type

    return manufacturer, UNKNOWN


def parse_transcript(text):
    metadata = {
        "scan_name": UNKNOWN,
        "scan_id": UNKNOWN,
        "scan_directory": UNKNOWN,
        "scan_started": UNKNOWN,
        "operating_system": UNKNOWN,
        "interface": UNKNOWN,
        "ip_address": UNKNOWN,
        "subnet_mask": UNKNOWN,
        "cidr_prefix": UNKNOWN,
        "local_ipv4_cidr": UNKNOWN,
    }
    hosts = {}
    order = []
    current_host = None

    for line in text.splitlines():
        stripped = line.strip()

        if line.startswith("Scan name:"):
            metadata["scan_name"] = value_after_colon(line)
            continue
        if line.startswith("Scan ID:"):
            metadata["scan_id"] = value_after_colon(line)
            continue
        if line.startswith("Scan directory:"):
            metadata["scan_directory"] = value_after_colon(line)
            continue
        if line.startswith("Scan start time:"):
            metadata["scan_started"] = value_after_colon(line)
            continue
        if line.startswith("Operating system:"):
            metadata["operating_system"] = value_after_colon(line)
            continue
        if line.startswith("Interface:"):
            metadata["interface"] = value_after_colon(line)
            continue
        if stripped.startswith("IP:"):
            metadata["ip_address"] = value_after_colon(stripped)
            continue
        if stripped.startswith("Subnet mask:"):
            metadata["subnet_mask"] = value_after_colon(stripped)
            continue
        if stripped.startswith("CIDR prefix:"):
            metadata["cidr_prefix"] = value_after_colon(stripped)
            continue
        if line.startswith("Local IPv4 CIDR:"):
            metadata["local_ipv4_cidr"] = value_after_colon(line)
            continue

        report_match = SCAN_REPORT_RE.match(line)
        if report_match:
            ip, hostname = parse_scan_report_target(report_match.group(1))
            current_host = get_host(hosts, order, ip)
            if hostname != UNKNOWN:
                current_host["hostname"] = hostname
            continue

        if current_host is None:
            continue

        up_match = HOST_UP_RE.match(line)
        if up_match:
            current_host["status"] = "up"
            if up_match.group(1):
                current_host["latency"] = up_match.group(1)
            continue

        mac_match = MAC_RE.match(line)
        if mac_match:
            current_host["mac"] = mac_match.group(1).upper()
            vendor = mac_match.group(2)
            if vendor:
                current_host["vendor"] = vendor
            continue

    return metadata, [hosts[ip] for ip in order]


def render(metadata, hosts):
    lines = [
        f"Scan name: {metadata['scan_name']}",
        f"Scan ID: {metadata['scan_id']}",
        f"Scan directory: {metadata['scan_directory']}",
        f"Scan started: {metadata['scan_started']}",
        f"Operating system: {metadata['operating_system']}",
        f"Interface: {metadata['interface']}",
        f"IP address: {metadata['ip_address']}",
        f"Subnet mask: {metadata['subnet_mask']}",
        f"CIDR prefix: {metadata['cidr_prefix']}",
        f"Network: {metadata['local_ipv4_cidr']}",
        f"Hosts discovered: {len(hosts)}",
    ]

    for host in hosts:
        manufacturer, probable_type = derive_manufacturer_and_type(host["vendor"])
        lines.append("")
        lines.extend(
            [
                f"Host: {host['ip']}",
                f"    Status: {host['status']}",
                f"    Latency: {host['latency']}",
                f"    MAC address: {host['mac']}",
                f"    Vendor: {host['vendor']}",
                f"    Manufacturer: {manufacturer}",
                f"    Probable type: {probable_type}",
                f"    Hostname: {host['hostname']}",
            ]
        )

    return "\n".join(lines) + "\n"


def render_review(prompt, enriched):
    if not prompt.endswith("\n") or prompt.endswith("\n\n"):
        raise ValueError("Prompt template must end with exactly one newline.")

    return (
        prompt
        + "\n"
        + "--- BEGIN ENRICHED TRANSCRIPT ---\n\n"
        + enriched
        + "--- END ENRICHED TRANSCRIPT ---\n"
    )


def atomic_write(path, content):
    directory = path.parent
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=directory,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as tmp:
        tmp.write(content)
        tmp_name = tmp.name

    try:
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        finally:
            raise


def main_for_transcript(transcript_path):
    text = transcript_path.read_text(encoding="utf-8")
    metadata, hosts = parse_transcript(text)
    enriched_path = transcript_path.with_name("transcript-enriched.txt")
    review_path = transcript_path.with_name("transcript-review.txt")
    enriched = render(metadata, hosts)
    prompt = PROMPT_PATH.read_text(encoding="utf-8")
    atomic_write(enriched_path, enriched)
    atomic_write(review_path, render_review(prompt, enriched))


def main():
    parser = argparse.ArgumentParser(
        description="Create transcript-enriched.txt beside an operator scan transcript."
    )
    parser.add_argument("transcript", help="Path to an existing transcript.txt")
    args = parser.parse_args()

    transcript_path = Path(args.transcript)
    if not transcript_path.is_file():
        parser.error(f"transcript does not exist: {transcript_path}")

    main_for_transcript(transcript_path)


if __name__ == "__main__":
    main()
