# AKWA board monitor

This app polls the eight boards over SSH and displays current uptime, reboot history, and the latest monitoring sample from each file in `/home/admin/device-client-logs/seconde`.

## Run

1. Copy `.env.example` to `.env` and set `SSH_USER` (the default is `admin`). The Wi-Fi values are included for deployment configuration; this monitor does not silently change network state.
2. Make sure the runner can SSH to each IP with a key or an already configured SSH agent. Test one board with `ssh admin@192.168.1.25`.
3. Run `npm run dev`, then open `http://localhost:5173`.

The API polls in parallel at `GET /api/devices`. Each reboot file is identified by its boot UUID. The collector uses the Linux filesystem birth time when available and falls back to modification time, because some filesystems do not expose creation time.

If SSH reports `Host key verification failed`, review the exact host entry with `ssh-keygen -F <ip>` and update the known host only after verifying the board identity. If it reports `Permission denied`, install the correct public key for `admin` or configure the intended SSH authentication method.
