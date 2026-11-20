"""Read-only board UART smoke validation using only the Python standard library."""
from __future__ import annotations

import os
from pathlib import Path
import re
import select
import termios
import time


class BoardValidationError(RuntimeError):
    """A serial board check could not prove a healthy application response."""


def serial_candidates() -> list[str]:
    by_id = Path("/dev/serial/by-id")
    if not by_id.is_dir():
        return []
    return sorted(str(path) for path in by_id.iterdir() if path.exists())


def preferred_uart_candidates(candidates: list[str] | None = None) -> list[str]:
    values = candidates if candidates is not None else serial_candidates()
    return [value for value in values if re.search(r"-if01-port0$", value)]


def _configure_uart(fd: int, baud: int) -> None:
    speed = getattr(termios, f"B{baud}", None)
    if speed is None:
        raise BoardValidationError(f"Unsupported UART baud rate {baud}")
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = speed
    attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def _read_until_prompt(fd: int, timeout_s: float, data: bytearray) -> str:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        readable, _, _ = select.select([fd], [], [], min(remaining, 0.25))
        if not readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if not chunk:
            continue
        data.extend(chunk)
        if b"> " in data:
            return data.decode("utf-8", errors="replace")
    return data.decode("utf-8", errors="replace")


def _command(fd: int, command: str, timeout_s: float) -> str:
    response = bytearray()
    payload = command.encode("utf-8") + b"\r"
    written = os.write(fd, payload)
    if written != len(payload):
        raise BoardValidationError(f"Short UART write for command {command!r}")
    return _read_until_prompt(fd, timeout_s, response)


def _require(response: str, marker: str, command: str) -> None:
    if marker not in response:
        raise BoardValidationError(
            f"UART command {command!r} did not return {marker!r}; "
            f"received {response[-1200:]!r}"
        )


def _parse_number(response: str, key: str, base: int = 10) -> int:
    match = re.search(rf"\b{re.escape(key)}=([0-9A-Fa-fx]+)", response)
    if match is None:
        raise BoardValidationError(f"UART response is missing {key}=...: {response[-1200:]!r}")
    try:
        return int(match.group(1), 0 if match.group(1).lower().startswith("0x") else base)
    except ValueError as exc:
        raise BoardValidationError(f"Invalid {key} value {match.group(1)!r}") from exc


def validate_uart(
    device: str,
    *,
    rom_path: str | None = None,
    run_fps: bool = True,
    baud: int = 115200,
    command_timeout_s: float = 8.0,
) -> dict[str, object]:
    """Query the running PS app and verify ROM, capture, and VDMA error status."""
    if os.name != "posix":
        raise BoardValidationError("UART validation requires the Linux POSIX serial interface.")
    if not device:
        raise BoardValidationError("UART device is required; use /dev/serial/by-id or --serial.")
    if rom_path is not None and (not rom_path or any(ch.isspace() or ch in "\r\n" for ch in rom_path)):
        raise BoardValidationError("ROM path must not contain whitespace or line breaks.")
    flags = os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK
    try:
        fd = os.open(device, flags)
    except OSError as exc:
        raise BoardValidationError(f"Cannot open UART device {device}: {exc}") from exc
    transcript: list[str] = []
    try:
        _configure_uart(fd, baud)
        termios.tcflush(fd, termios.TCIFLUSH)

        if rom_path is not None:
            load = _command(fd, f"rom load {rom_path}", 120.0)
            _require(load, "[CMD] rom load ok", f"rom load {rom_path}")
            transcript.append(f">>> rom load {rom_path}\n" + load)

        first_status = _command(fd, "status", command_timeout_s)
        _require(first_status, "[STAT] frame=", "status")
        _require(first_status, "vdma_sr=", "status")
        _require(first_status, "vdma_err=", "status")
        _require(first_status, "dma_err=", "status")
        transcript.append(">>> status\n" + first_status)
        first_cap_match = re.search(r"cap_seq=(\d+)", first_status)
        if first_cap_match is None:
            raise BoardValidationError("Could not parse initial capture sequence.")

        rom_status = _command(fd, "rom status", command_timeout_s)
        _require(rom_status, "[CMD] rom loaded=", "rom status")
        _require(rom_status, "[CMD] rom path=", "rom status")
        transcript.append(">>> rom status\n" + rom_status)
        loaded_match = re.search(r"\[CMD\] rom loaded=(\d+)", rom_status)
        if loaded_match is None:
            raise BoardValidationError("ROM status has no loaded flag.")
        loaded = int(loaded_match.group(1))
        rom_bytes = _parse_number(rom_status, "bytes")
        if rom_path is not None and (loaded != 1 or rom_bytes <= 0 or rom_path not in rom_status):
            raise BoardValidationError(
                f"Requested ROM did not load with the full path and nonzero size: {rom_status[-1200:]!r}"
            )

        if run_fps:
            fps = _command(fd, "fps 10 100", 20.0)
            _require(fps, "[FPS] blit_shadow_sparse_hash_changes=", "fps 10 100")
            transcript.append(">>> fps 10 100\n" + fps)

        time.sleep(0.2)
        final_status = _command(fd, "status", command_timeout_s)
        _require(final_status, "[STAT] frame=", "final status")
        transcript.append(">>> final status\n" + final_status)

        status_match = re.search(
            r"\[STAT\] frame=(\d+) miss=(\d+) vsync=(\d+).*?"
            r"vdma_sr=(0x[0-9A-Fa-f]+) vdma_irq=(\d+) vdma_err=(\d+) "
            r"dma_err=(0x[0-9A-Fa-f]+) cap_seq=(\d+) cap_buf=(\d+)",
            final_status,
        )
        if status_match is None:
            raise BoardValidationError("Could not parse full frame/VDMA status line.")
        frame_idx, cycles_missing, vsync, vdma_sr, vdma_irq, vdma_err, dma_err, cap_seq, cap_buf = status_match.groups()
        if int(vdma_err) != 0 or int(dma_err, 16) != 0:
            raise BoardValidationError(
                f"Video/DMA error counters are nonzero: vdma_err={vdma_err} dma_err={dma_err}"
            )
        capture_sequence_start = int(first_cap_match.group(1))
        capture_sequence_end = int(cap_seq)
        capture_sequence_delta = (capture_sequence_end - capture_sequence_start) & 0xFFFFFFFF
        if loaded and capture_sequence_delta == 0:
            raise BoardValidationError("ROM is loaded but the capture sequence did not advance.")
        if loaded and rom_bytes <= 0:
            raise BoardValidationError("A loaded ROM reports zero bytes.")
        return {
            "device": device,
            "baud": baud,
            "rom_loaded": loaded,
            "rom_bytes": rom_bytes,
            "rom_path": re.search(r"\[CMD\] rom path=([^\r\n]+)", rom_status).group(1).strip(),
            "frame_index": int(frame_idx),
            "cycles_missing": int(cycles_missing),
            "vsync_speed": int(vsync),
            "vdma_status": vdma_sr,
            "vdma_irq_count": int(vdma_irq),
            "vdma_error_count": int(vdma_err),
            "dma_error_mask": dma_err,
            "capture_sequence_start": capture_sequence_start,
            "capture_sequence": capture_sequence_end,
            "capture_sequence_delta": capture_sequence_delta,
            "capture_buffer": int(cap_buf),
            "fps_ran": run_fps,
            "transcript": "\n".join(transcript),
        }
    finally:
        os.close(fd)
