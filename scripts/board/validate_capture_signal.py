#!/usr/bin/env python3
"""Validate gameplay HDMI audio through UART plus an FFmpeg capture."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import termios


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.board.validation import _command, _configure_uart, validate_uart


def _audio_status(device: str) -> str:
    fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        _configure_uart(fd, 115200)
        termios.tcflush(fd, termios.TCIFLUSH)
        response = _command(fd, "audio status", 8.0)
    finally:
        os.close(fd)
    required = (r"\[CMD\] audio\b", r"\bpath=HDMI\b", r"\broute=idle\b",
                r"\brequested=HDMI\b", r"\berr=0\b", r"\bpcm_overflow=0\b",
                r"\bmute=0\b", r"\bvol=([1-9][0-9]*)\b")
    missing = [pattern for pattern in required if not re.search(pattern, response)]
    if missing:
        raise RuntimeError(f"audio route is not ready or status is incomplete: {response[-1200:]!r}")
    return response


def _run_ffmpeg_capture(input_format: str, input_name: str, seconds: float, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", input_format, "-i", input_name,
        "-t", str(seconds), "-vn", "-ac", "2", "-ar", "48000",
        "-y", str(output),
    ]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
    if result.returncode or not output.is_file() or output.stat().st_size == 0:
        raise RuntimeError(f"FFmpeg capture failed: {result.stderr.strip()}")


def _measure_audio(path: Path, min_peak_db: float, min_mean_db: float) -> dict[str, float]:
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    text = (result.stdout or "") + "\n" + (result.stderr or "")
    mean = re.search(r"mean_volume:\s*(-?[0-9.]+) dB", text)
    peak = re.search(r"max_volume:\s*(-?[0-9.]+) dB", text)
    if result.returncode or not mean or not peak:
        raise RuntimeError("FFmpeg did not produce volumedetect metrics")
    values = {"mean_volume_db": float(mean.group(1)), "max_volume_db": float(peak.group(1))}
    if values["max_volume_db"] < min_peak_db or values["mean_volume_db"] < min_mean_db:
        raise RuntimeError(f"no capture signal above the configured thresholds: {values}")
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", default=os.environ.get("FPGA_UART_DEVICE"))
    parser.add_argument("--rom", required=True)
    parser.add_argument("--capture-input", default=os.environ.get("FPGA_CAPTURE_INPUT"))
    parser.add_argument("--capture-format", default=os.environ.get("FPGA_CAPTURE_FORMAT", "alsa"))
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--min-peak-db", type=float, default=-80.0)
    parser.add_argument("--min-mean-db", type=float, default=-90.0)
    parser.add_argument("--output", default="build/board/gameplay_audio_signal/capture.wav")
    args = parser.parse_args()
    if not args.serial or not args.capture_input:
        parser.error("--serial and --capture-input are required")
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    try:
        status = validate_uart(args.serial, rom_path=args.rom, run_fps=False)
        audio_status = _audio_status(args.serial)
        output = ROOT / args.output
        _run_ffmpeg_capture(args.capture_format, args.capture_input, args.seconds, output)
        metrics = _measure_audio(output, args.min_peak_db, args.min_mean_db)
        with output.open("rb") as stream:
            audio_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
        evidence = {
            "rom": args.rom,
            "capture_input": args.capture_input,
            "capture_format": args.capture_format,
            "seconds": args.seconds,
            "capture": output.relative_to(ROOT).as_posix(),
            "capture_sha256": audio_sha256,
            "metrics": metrics,
            "thresholds_db": {"peak": args.min_peak_db, "mean": args.min_mean_db},
            "uart_status": status,
            "uart_audio_status": audio_status,
            "observed_at_utc": datetime.now(timezone.utc).isoformat(),
            "scope": "non-silent captured signal during confirmed gameplay; not a listening-quality assessment",
            "status": "passed",
        }
        report = output.with_suffix(".json")
        report.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"GAMEPLAY_AUDIO_SIGNAL_PASS mean_volume_db={metrics['mean_volume_db']:.2f} max_volume_db={metrics['max_volume_db']:.2f}")
        return 0
    except Exception as exc:
        print(f"GAMEPLAY_AUDIO_SIGNAL_FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
