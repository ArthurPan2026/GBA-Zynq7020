#!/usr/bin/env python3
"""Validate gameplay HDMI audio through UART plus an FFmpeg capture."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]


def _serial_exchange(device: str, commands: list[str], timeout: float) -> str:
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("pyserial is required for gameplay_audio_signal validation") from exc
    transcript: list[str] = []
    with serial.Serial(device, 115200, timeout=0.1) as port:
        port.reset_input_buffer()
        for command in commands:
            port.write((command + "\r\n").encode("utf-8"))
            port.flush()
            deadline = time.monotonic() + timeout
            response = bytearray()
            while time.monotonic() < deadline:
                response.extend(port.read(4096))
                text = response.decode("utf-8", errors="replace")
                if ">" in text:
                    break
            line = response.decode("utf-8", errors="replace")
            transcript.append(f"$ {command}\n{line}")
            if not line:
                raise RuntimeError(f"UART command timed out: {command}")
    return "\n".join(transcript)


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


def _measure_audio(path: Path) -> dict[str, float]:
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
    if values["max_volume_db"] <= -90.0:
        raise RuntimeError(f"captured HDMI audio is effectively silent: {values}")
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", default=os.environ.get("FPGA_UART_DEVICE"))
    parser.add_argument("--rom", required=True)
    parser.add_argument("--capture-input", default=os.environ.get("FPGA_CAPTURE_INPUT"))
    parser.add_argument("--capture-format", default=os.environ.get("FPGA_CAPTURE_FORMAT", "v4l2"))
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--output", default="out/board/gameplay_audio_signal/capture.wav")
    args = parser.parse_args()
    if not args.serial or not args.capture_input:
        parser.error("--serial and --capture-input are required")
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    try:
        transcript = _serial_exchange(
            args.serial,
            [f"rom load {args.rom}", "rom status", "audio status"],
            timeout=45.0,
        )
        output = ROOT / args.output
        _run_ffmpeg_capture(args.capture_format, args.capture_input, args.seconds, output)
        metrics = _measure_audio(output)
        evidence = {
            "rom": args.rom,
            "capture_input": args.capture_input,
            "capture_format": args.capture_format,
            "seconds": args.seconds,
            "capture": output.relative_to(ROOT).as_posix(),
            "metrics": metrics,
            "uart_transcript": transcript,
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
