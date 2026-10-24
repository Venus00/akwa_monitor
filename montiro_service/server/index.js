import express from 'express';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import 'dotenv/config';
import { Client } from 'ssh2';

const execFileAsync = promisify(execFile);
const app = express();
app.use(express.json());

const devices = [
  ['HARDIOTM71090E25D', '192.168.1.25', 'cc:c4:b2:7c:90:74'],
  ['HARDIOTM77E79EC4E', '192.168.1.148', 'cc:c4:b2:7c:90:ab'],
  ['HARDIOTM775CADCEA', '192.168.1.27', 'cc:c4:b2:7c:92:17'],
  ['HARDIOTM7B9404A9B', '192.168.1.30', 'cc:c4:b2:7c:90:c5'],
  ['HARDIOTM735AAD8F8', '192.168.1.169', 'cc:c4:b2:7c:8f:e9'],
  ['HARDIOTM7E9B4DD73', '192.168.1.96', 'cc:c4:b2:7c:92:0e'],
  ['HARDIOTM7B67E30FB', '192.168.1.33', 'cc:c4:b2:7c:8f:a7'],
  ['HARDIOTM75862E63E', '192.168.1.180', 'cc:c4:b2:7c:8f:8e']
].map(([name, ip, mac]) => ({ name, ip, mac }));

const env = {
  user: process.env.SSH_USER || 'admin',
  password: process.env.SSH_PASSWORD || '',
  port: process.env.SSH_PORT || '22',
  timeout: process.env.SSH_CONNECT_TIMEOUT || '8',
  strictHostKeyChecking: process.env.SSH_STRICT_HOST_KEY_CHECKING || 'accept-new',
  logPath: process.env.DEVICE_LOG_PATH || '/home/admin/device-client-logs'
};

function runRemote(device, command) {
  return new Promise((resolve, reject) => {
    const client = new Client();
    let settled = false;
    const finish = (fn, value) => { if (!settled) { settled = true; client.end(); fn(value); } };
    const timer = setTimeout(() => finish(reject, new Error(`SSH connection timeout after ${env.timeout}s`)), (Number(env.timeout) + 4) * 1000);
    client.on('ready', () => client.exec(command, (error, stream) => {
      if (error) { clearTimeout(timer); return finish(reject, error); }
      let stdout = ''; let stderr = '';
      stream.on('data', (chunk) => { stdout += chunk.toString(); });
      stream.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
      stream.on('close', (code) => { clearTimeout(timer); if (code) finish(reject, new Error(stderr.trim() || `Remote command exited with code ${code}`)); else finish(resolve, { stdout, stderr }); });
    }));
    client.on('error', (error) => { clearTimeout(timer); finish(reject, error); });
    client.connect({ host: device.ip, port: Number(env.port), username: env.user, password: env.password, readyTimeout: Number(env.timeout) * 1000, tryKeyboard: false });
  });
}

const remoteScript = (logPath) => `
set -eu
LOG_PATH='${logPath.replaceAll("'", "'\\''")}'
hostname=$(hostname 2>/dev/null || true)
uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)
printf 'HOSTNAME=%s\\nUPTIME_SECONDS=%s\\n' "$hostname" "$uptime_seconds"
for f in $(find "$LOG_PATH/seconde" -maxdepth 1 -type f -name '*.csv' 2>/dev/null | head -200); do
  birth=$(stat -c '%W' "$f" 2>/dev/null || echo 0)
  modified=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
  [ "$birth" -gt 0 ] || birth="$modified"
  file=$(basename "$f")
  printf 'FILE|%s|%s|%s\\n' "$birth" "$modified" "$file"
  last=$(tail -n 1 "$f" 2>/dev/null || true)
  printf 'SAMPLE|%s|%s\\n' "$file" "$last"
done | sort -t'|' -k2,2nr | head -400
`;

function parseDuration(text) {
  const m = String(text || '').match(/(\d+)\s*j\s+(\d+)\s*h\s+(\d+)\s*min\s+(\d+)\s*s/);
  return m ? Number(m[1]) * 86400 + Number(m[2]) * 3600 + Number(m[3]) * 60 + Number(m[4]) : null;
}

async function collect(device) {
  const started = Date.now();
  try {
    const { stdout } = await runRemote(device, remoteScript(env.logPath));
    const lines = stdout.trim().split(/\r?\n/).filter(Boolean);
    const meta = Object.fromEntries(lines.filter((line) => line.includes('=')).map((line) => line.split('=')));
    const samples = new Map(lines.filter((line) => line.startsWith('SAMPLE|')).map((line) => { const [, file, raw] = line.split('|'); return [file, raw]; }));
    const files = lines.filter((line) => line.startsWith('FILE|')).map((line) => {
      const [, birth, modified, file] = line.split('|');
      const bootId = file.match(/fifo-demarrage-([0-9a-f-]+)\./i)?.[1] || null;
      const columns = (samples.get(file) || '').split(';');
      const durationSeconds = Number(columns[4]);
      const sampleAt = columns[0] || null;
      const sampleDate = sampleAt ? new Date(sampleAt) : null;
      const rebootAt = sampleDate && !Number.isNaN(sampleDate.getTime()) && Number.isFinite(durationSeconds) ? new Date(sampleDate.getTime() - durationSeconds * 1000).toISOString() : null;
      return { file, bootId, createdAt: new Date(Number(birth) * 1000).toISOString(), modifiedAt: new Date(Number(modified) * 1000).toISOString(), rebootAt, sample: columns.length >= 17 ? { at: sampleAt, durationSeconds, cpuPercent: columns[5], memoryPercent: columns[9], temperatureC: columns[10], diskPercent: columns[13], load1: columns[14] } : null };
    }).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
    return { ...device, status: 'online', hostname: meta.HOSTNAME || device.name, uptimeSeconds: Number(meta.UPTIME_SECONDS || 0), reboots: files, monitoring: files.slice(0, 20).map(({ file, sample }) => ({ file, ...sample })).filter((row) => row.at), latestBoot: files[0]?.bootId || null, checkedAt: new Date().toISOString(), latencyMs: Date.now() - started };
  } catch (error) {
    return { ...device, status: 'offline', error: error.code === 'ENOENT' ? 'ssh command not found' : (error.stderr || error.message).trim(), reboots: [], checkedAt: new Date().toISOString(), latencyMs: Date.now() - started };
  }
}

async function collectAll() { return Promise.all(devices.map(collect)); }

app.get('/api/devices', async (_req, res) => res.json({ checkedAt: new Date().toISOString(), devices: await collectAll() }));
app.get('/api/config', (_req, res) => res.json({ deviceCount: devices.length, logPath: env.logPath, wifiSsid: process.env.WIFI_SSID || 'NXT-AP2', wifiConnectEnabled: process.env.ENABLE_WIFI_CONNECT === 'true' }));
app.get('/api/report.pdf', async (_req, res) => {
  const tempBase = path.join(os.tmpdir(), `akwa-factory-report-${Date.now()}`);
  const jsonPath = `${tempBase}.json`;
  const pdfPath = `${tempBase}.pdf`;
  try {
    const payload = { generatedAt: new Date().toISOString(), logPath: env.logPath, devices: await collectAll() };
    await fs.writeFile(jsonPath, JSON.stringify(payload), 'utf8');
    const reportScript = path.join(path.dirname(fileURLToPath(import.meta.url)), 'report.py');
    await execFileAsync(process.env.PYTHON_BIN || 'python', [reportScript, jsonPath, pdfPath], { timeout: 30000 });
    const pdf = await fs.readFile(pdfPath);
    res.set({ 'Content-Type': 'application/pdf', 'Content-Disposition': 'attachment; filename="akwa-factory-test-report.pdf"' }).send(pdf);
  } catch (error) {
    res.status(500).json({ error: error.stderr || error.message });
  } finally {
    await Promise.allSettled([fs.unlink(jsonPath), fs.unlink(pdfPath)]);
  }
});

const clientRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
app.use(express.static(clientRoot));
app.use((_req, res) => res.sendFile(path.join(clientRoot, 'index.html')));
app.listen(3001, () => console.log('Board monitor API listening on http://localhost:3001'));
