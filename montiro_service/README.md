# AKWA board monitor

This app polls the eight boards over SSH and displays current uptime, reboot history, and the latest monitoring sample from each file in `/home/admin/device-client-logs/seconde`.

## Run

1. Copy `.env.example` to `.env` and set `SSH_USER` and `SSH_PASSWORD` (the default user is `admin`). The password is used only by the server-side SSH collector and is never sent to the browser. The Wi-Fi values are included for deployment configuration; this monitor does not silently change network state.
2. Test one board with `ssh admin@192.168.1.25` or start the monitor and use the dashboard status cards.
3. Run `npm run dev`, then open `http://localhost:5173`.

The API polls in parallel at `GET /api/devices`. Each reboot file is identified by its boot UUID. The collector uses the Linux filesystem birth time when available and falls back to modification time, because some filesystems do not expose creation time.

The dashboard's **Download PDF report** action calls `GET /api/report.pdf`. It collects a fresh fleet snapshot and generates a factory report containing the AKWA client name, report date, test scope, acceptance checks, per-board SSH result, uptime, reboot times, last-row monitoring values, and recent kernel error messages from both `dmesg` and `journalctl -k`. The report generator requires Python, ReportLab, and the timezone database: `python -m pip install -r server/requirements.txt`. Set `PYTHON_BIN` in `.env` if the Python executable is not on PATH.

Place the FMC2E logo at `assets/fmc2e-logo.png`, or set `FMC2E_LOGO_PATH` to an image path. PNG, JPG, and other formats supported by ReportLab are accepted. The report uses a small `FMC2E` text mark until the image is available.

If SSH reports `Permission denied`, verify `SSH_USER`, `SSH_PASSWORD`, port 22, and that password authentication is enabled on the board.
