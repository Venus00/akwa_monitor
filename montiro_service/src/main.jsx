import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import './tag.css';

const fmtDuration = (seconds) => {
  if (!Number.isFinite(seconds)) return '—';
  const d = Math.floor(seconds / 86400); const h = Math.floor(seconds / 3600) % 24; const m = Math.floor(seconds / 60) % 60;
  return `${d}j ${h}h ${m}m`;
};
const fmtDate = (value) => value ? new Date(value).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'medium' }) : '—';

function App() {
  const [data, setData] = useState({ devices: [] }); const [loading, setLoading] = useState(true); const [error, setError] = useState(''); const [selected, setSelected] = useState(null); const [plannedReboots, setPlannedReboots] = useState(() => { try { return JSON.parse(localStorage.getItem('akwa-planned-reboots') || '{}'); } catch { return {}; } });
  const refresh = async () => { setLoading(true); setError(''); try { const res = await fetch('/api/devices'); if (!res.ok) throw new Error('API indisponible'); setData(await res.json()); } catch (e) { setError(e.message); } finally { setLoading(false); } };
  useEffect(() => { refresh(); const id = setInterval(refresh, 30000); return () => clearInterval(id); }, []);
  const rebootKey = (device, reboot) => `${device.ip}:${reboot.file}`;
  const setPlanned = (device, reboot, planned) => setPlannedReboots((current) => { const next = { ...current, [rebootKey(device, reboot)]: planned }; localStorage.setItem('akwa-planned-reboots', JSON.stringify(next)); return next; });
  const downloadReport = async () => { setError(''); try { const res = await fetch('/api/report.pdf', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ plannedReboots }) }); if (!res.ok) throw new Error('Generation du rapport impossible'); const blob = await res.blob(); const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = 'akwa-factory-test-report.pdf'; link.click(); URL.revokeObjectURL(url); } catch (e) { setError(e.message); } };
  const online = useMemo(() => data.devices.filter((d) => d.status === 'online').length, [data]);
  return <main><header><div><div className="eyebrow">AKWA / MONITORING</div><h1>Board fleet health</h1><p>Uptime, reboots and monitoring history collected over SSH.</p></div><div className="actions"><button onClick={downloadReport}>Download PDF report</button><button onClick={refresh} disabled={loading}>{loading ? 'Collecting…' : 'Refresh now'}</button></div></header>
    <section className="summary"><div><span>Boards</span><strong>{data.devices.length || 8}</strong></div><div><span>Online</span><strong className="green">{online}</strong></div><div><span>Offline</span><strong className="red">{Math.max(0, (data.devices.length || 8) - online)}</strong></div><div><span>Last check</span><strong>{fmtDate(data.checkedAt)}</strong></div></section>
    {error && <div className="notice">{error}. Check SSH key access, network connectivity and that OpenSSH is installed.</div>}
    <section className="grid">{data.devices.map((device) => <article className={`card ${device.status}`} key={device.ip} onClick={() => setSelected(device)}><div className="cardHead"><div><div className="tag">{device.tag || 'BOARD'}</div><h2>{device.name}</h2><span>{device.ip} · {device.mac}</span></div><i className="dot" /></div><div className="metric"><span>Uptime</span><b>{fmtDuration(device.uptimeSeconds)}</b></div><div className="metric"><span>Latest boot</span><b>{device.latestBoot ? device.latestBoot.slice(0, 8) : '—'}</b></div><div className="cardFoot"><span>{device.status === 'online' ? `${device.reboots.length} reboot file(s)` : device.error}</span><span>{device.latencyMs ? `${device.latencyMs} ms` : ''}</span></div></article>)}</section>
    {selected && <div className="overlay" onClick={() => setSelected(null)}><aside onClick={(e) => e.stopPropagation()}><button className="close" onClick={() => setSelected(null)}>×</button><div className="eyebrow">REBOOT HISTORY</div><h2>{selected.name}</h2><p className="muted">{selected.ip} · current uptime {fmtDuration(selected.uptimeSeconds)}</p>{selected.reboots.length ? <div className="history">{selected.reboots.map((r) => <div key={r.file}><span className="timeline" /><div><b>{r.rebootAt ? `Reboot ${fmtDate(r.rebootAt)}` : `File ${fmtDate(r.createdAt)}`}</b><small>{r.bootId || r.file}</small>{r.sample && <small>Last row: {fmtDate(r.sample.at)} · uptime {fmtDuration(r.sample.durationSeconds)}</small>}{r.sample && <small>CPU {r.sample.cpuPercent}% · RAM {r.sample.memoryPercent}% · temp {r.sample.temperatureC}°C · disk {r.sample.diskPercent}%</small>}<label className="planned"><input type="checkbox" checked={Boolean(plannedReboots[rebootKey(selected, r)])} onChange={(e) => setPlanned(selected, r, e.target.checked)} /> Redémarrage planifié</label></div></div>)}</div> : <div className="empty">No reboot files were returned. The board may be offline or the path may be unavailable.</div>}</aside></div>}
  </main>;
}
createRoot(document.getElementById('root')).render(<App />);
