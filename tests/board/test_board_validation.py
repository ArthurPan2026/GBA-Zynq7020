from __future__ import annotations

import os
import pty
import select
import threading
import unittest

from scripts.board.validation import (
    BoardValidationError,
    preferred_uart_candidates,
    validate_uart,
)


class BoardValidationTests(unittest.TestCase):
    def test_prefers_stable_ftdi_interface_b_path(self):
        values = [
            "/dev/serial/by-id/usb-Digilent_Adept-if00-port0",
            "/dev/serial/by-id/usb-Digilent_Adept-if01-port0",
        ]
        self.assertEqual(preferred_uart_candidates(values), [values[1]])

    def _run_emulated_uart(self, dma_error="0x000", rom_path=None):
        master, slave = pty.openpty()
        device = os.ttyname(slave)
        stop = threading.Event()
        captured = []
        state = {"status": 0, "rom_path": "0:/games/Existing.gba", "rom_bytes": 4096}

        def emulator():
            pending = bytearray()
            while not stop.is_set():
                readable, _, _ = select.select([master], [], [], 0.05)
                if not readable:
                    continue
                try:
                    data = os.read(master, 256)
                except OSError:
                    break
                for byte in data:
                    if byte == 13:
                        command = pending.decode("utf-8", errors="replace")
                        pending.clear()
                        captured.append(command)
                        if command == "help":
                            response = "rom status\r\n> "
                        elif command == "rom status":
                            response = (
                                f"[CMD] rom loaded=1 busy=0 bytes={state['rom_bytes']} aligned=4096 maxpak=0x0\r\n"
                                "[CMD] bios mode=internal ext=0 load_ok=1 bytes=16384\r\n"
                                f"[CMD] rom path={state['rom_path']}\r\n> "
                            )
                        elif command.startswith("rom load "):
                            state["rom_path"] = command[len("rom load "):]
                            state["rom_bytes"] = 8192
                            response = "[CMD] rom load ok\r\n> "
                        elif command == "status":
                            state["status"] += 1
                            seq = state["status"] * 5
                            response = (
                                f"[STAT] frame={state['status']} miss=0 vsync=60 rom=1 busy=0 "
                                f"irq=0x0 err=0x00000000 park=1 vdma_sr=0x00000002 "
                                f"vdma_irq=4 vdma_err=0 dma_err={dma_error} cap_seq={seq} cap_buf=1\r\n"
                                "[STAT] blit count=10 last_us=10 max_us=20 avg_us=12 seq_gap_max=0\r\n> "
                            )
                        elif command == "fps 10 100":
                            response = (
                                "[FPS] elapsed=10000 ms cycles_missing=0->0 cycles_missing_delta=0\r\n"
                                "[FPS] capture_seq_fps=60.00 ps_frame_submit_fps=60.00 scaler_frames_completed_fps=60.00\r\n"
                                "[FPS] blit_shadow_sparse_hash_changes=4 blit_shadow_sparse_hash_hz=0.40\r\n> "
                            )
                        else:
                            response = f"[CMD] unknown: {command}\r\n> "
                        os.write(master, response.encode("utf-8"))
                    elif byte not in (10,):
                        pending.append(byte)

        thread = threading.Thread(target=emulator, daemon=True)
        thread.start()
        try:
            result = validate_uart(
                device, rom_path=rom_path, run_fps=True, command_timeout_s=1.0
            )
            return result, captured
        finally:
            stop.set()
            thread.join(timeout=1)
            os.close(master)
            os.close(slave)

    def test_uart_smoke_checks_status_rom_and_fps_without_saving(self):
        path = "0:/games/测试.gba"
        result, commands = self._run_emulated_uart(rom_path=path)
        self.assertIn("rom load " + path, commands)
        self.assertIn("status", commands)
        self.assertIn("rom status", commands)
        self.assertIn("fps 10 100", commands)
        self.assertNotIn("savestate", " ".join(commands))
        self.assertEqual(result["rom_path"], path)
        self.assertEqual(result["rom_bytes"], 8192)
        self.assertEqual(result["vdma_error_count"], 0)
        self.assertEqual(result["dma_error_mask"], "0x000")

    def test_uart_smoke_fails_on_dma_error(self):
        with self.assertRaisesRegex(BoardValidationError, "error counters are nonzero"):
            self._run_emulated_uart(dma_error="0x004")


if __name__ == "__main__":
    unittest.main()
