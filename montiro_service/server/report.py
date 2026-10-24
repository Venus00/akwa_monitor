import json
import sys
from datetime import datetime
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak

NAVY = colors.HexColor('#0B1721')
INK = colors.HexColor('#1A2A34')
MUTED = colors.HexColor('#61737E')
TEAL = colors.HexColor('#147D68')
PALE = colors.HexColor('#EAF5F1')
RED = colors.HexColor('#A83C49')

def date_text(value):
    if not value:
        return '-'
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).strftime('%Y-%m-%d %H:%M:%S %z')
    except Exception:
        return str(value)

def duration(seconds):
    if seconds is None:
        return '-'
    try:
        s = int(float(seconds))
        return f'{s // 86400}d {(s // 3600) % 24}h {(s // 60) % 60}m {s % 60}s'
    except Exception:
        return '-'

def para(text, style):
    return Paragraph(str(text).replace('&', '&amp;'), style)

def footer(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(colors.HexColor('#D9E2E5'))
    canvas.line(18 * mm, 14 * mm, 192 * mm, 14 * mm)
    canvas.setFont('Helvetica', 8)
    canvas.setFillColor(MUTED)
    canvas.drawString(18 * mm, 9 * mm, 'AKWA | Factory board monitoring report')
    canvas.drawRightString(192 * mm, 9 * mm, f'Page {doc.page}')
    canvas.restoreState()

def build_report(source, output):
    with open(source, encoding='utf-8') as stream:
        payload = json.load(stream)
    devices = payload.get('devices', [])
    online = sum(device.get('status') == 'online' for device in devices)
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name='TitleX', parent=styles['Title'], fontName='Helvetica-Bold', fontSize=26, leading=30, textColor=colors.white))
    styles.add(ParagraphStyle(name='SubX', parent=styles['Normal'], fontSize=9, leading=13, textColor=colors.HexColor('#B8D5CF')))
    styles.add(ParagraphStyle(name='H1X', parent=styles['Heading1'], fontName='Helvetica-Bold', fontSize=16, leading=20, textColor=NAVY, spaceBefore=10, spaceAfter=8))
    styles.add(ParagraphStyle(name='H2X', parent=styles['Heading2'], fontName='Helvetica-Bold', fontSize=11, leading=14, textColor=TEAL, spaceBefore=7, spaceAfter=4))
    styles.add(ParagraphStyle(name='BodyX', parent=styles['BodyText'], fontSize=9, leading=13, textColor=INK, spaceAfter=5))
    styles.add(ParagraphStyle(name='SmallX', parent=styles['BodyText'], fontSize=7.2, leading=9.5, textColor=MUTED))
    styles.add(ParagraphStyle(name='WhiteX', parent=styles['BodyText'], fontSize=9, leading=12, textColor=colors.white))
    doc = SimpleDocTemplate(output, pagesize=A4, rightMargin=18*mm, leftMargin=18*mm, topMargin=16*mm, bottomMargin=20*mm, title='AKWA Factory Test Report', author='AKWA Monitoring')
    story = []
    report_id = datetime.now().strftime('AKWA-%Y%m%d-%H%M%S')
    header = Table([[para('AKWA', styles['SubX']), para('FACTORY TEST REPORT', styles['TitleX'])], [para('Board fleet commissioning and operational verification', styles['SubX']), para(f'Report ID: {report_id}<br/>Generated: {date_text(payload.get("generatedAt"))}', styles['SubX'])]], colWidths=[35*mm, 139*mm])
    header.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,-1), NAVY), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 12), ('RIGHTPADDING', (0,0), (-1,-1), 12), ('TOPPADDING', (0,0), (-1,-1), 11), ('BOTTOMPADDING', (0,0), (-1,-1), 11)]))
    story += [header, Spacer(1, 12)]
    summary = Table([[para('BOARDS TESTED', styles['SmallX']), para('ONLINE', styles['SmallX']), para('OFFLINE', styles['SmallX']), para('SOURCE', styles['SmallX'])], [para(len(devices), styles['H1X']), para(online, styles['H1X']), para(len(devices)-online, styles['H1X']), para(payload.get('logPath', '-'), styles['SmallX'])]], colWidths=[35*mm, 30*mm, 30*mm, 79*mm])
    summary.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,-1), PALE), ('BOX', (0,0), (-1,-1), 0.5, colors.HexColor('#B9DCD3')), ('VALIGN', (0,0), (-1,-1), 'MIDDLE'), ('LEFTPADDING', (0,0), (-1,-1), 9), ('RIGHTPADDING', (0,0), (-1,-1), 9), ('TOPPADDING', (0,0), (-1,-1), 8), ('BOTTOMPADDING', (0,0), (-1,-1), 8)]))
    story += [summary, Spacer(1, 14), para('Purpose and acceptance scope', styles['H1X']), para('This report records the factory verification state of the AKWA board fleet at the time of generation. It confirms SSH reachability, operating system uptime, reboot history, and the latest monitoring values available in each board\'s seconde log directory.', styles['BodyX']), para('Functional checks', styles['H2X'])]
    checks = [['Check', 'Method', 'Acceptance evidence'], ['Network and SSH', 'Open an SSH session using the configured server-side credentials.', 'Board returns a command response.'], ['Uptime', 'Read /proc/uptime from the board.', 'Current uptime is present and non-negative.'], ['Reboot history', 'Enumerate reboot CSV files and read the final row of each file.', 'Each file has a boot UUID and derived reboot time.'], ['Monitoring', 'Read the final semicolon-delimited row in each CSV.', 'Timestamp, uptime, CPU, memory, temperature and disk values are captured.']]
    check_table = Table([[para(cell, styles['SmallX']) for cell in row] for row in checks], colWidths=[31*mm, 72*mm, 71*mm], repeatRows=1)
    check_table.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), NAVY), ('TEXTCOLOR', (0,0), (-1,0), colors.white), ('GRID', (0,0), (-1,-1), 0.35, colors.HexColor('#D6E0E3')), ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, colors.HexColor('#F5F8F8')]), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 7), ('RIGHTPADDING', (0,0), (-1,-1), 7), ('TOPPADDING', (0,0), (-1,-1), 6), ('BOTTOMPADDING', (0,0), (-1,-1), 6)]))
    story += [check_table, PageBreak(), para('Board-by-board results', styles['H1X'])]
    for index, device in enumerate(devices):
        state = 'PASS - ONLINE' if device.get('status') == 'online' else 'FAIL - OFFLINE'
        state_style = ParagraphStyle(f'state{index}', parent=styles['SmallX'], textColor=TEAL if device.get('status') == 'online' else RED, alignment=2)
        title = Table([[para(f'{index+1:02d}  {device.get("name", "Unknown")}', styles['H2X']), para(state, state_style)]], colWidths=[120*mm, 54*mm])
        title.setStyle(TableStyle([('LINEBELOW', (0,0), (-1,-1), 0.7, colors.HexColor('#D6E0E3')), ('VALIGN', (0,0), (-1,-1), 'BOTTOM')]))
        story += [title, para(f'Tag: {device.get("tag", "BOARD")} | IP address: {device.get("ip", "-")} | MAC address: {device.get("mac", "-")} | Hostname: {device.get("hostname", "-")}', styles['SmallX'])]
        overview = [['Current uptime', 'Latest boot UUID', 'Latency', 'Checked at'], [duration(device.get('uptimeSeconds')), device.get('latestBoot') or '-', f'{device.get("latencyMs", "-")} ms', date_text(device.get('checkedAt'))]]
        overview_table = Table([[para(cell, styles['SmallX']) for cell in row] for row in overview], colWidths=[43*mm, 50*mm, 31*mm, 50*mm])
        overview_table.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), PALE), ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor('#D6E0E3')), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 6), ('RIGHTPADDING', (0,0), (-1,-1), 6), ('TOPPADDING', (0,0), (-1,-1), 5), ('BOTTOMPADDING', (0,0), (-1,-1), 5)]))
        story += [Spacer(1, 6), overview_table]
        if device.get('error'):
            story += [Spacer(1, 5), para(f'Connection result: {device["error"]}', styles['SmallX'])]
        else:
            rows = [['Derived reboot time', 'Last sample', 'Uptime', 'CPU', 'RAM', 'Temp', 'Disk']]
            for reboot in device.get('reboots', [])[:20]:
                sample = reboot.get('sample') or {}
                rows.append([date_text(reboot.get('rebootAt')), date_text(sample.get('at')), duration(sample.get('durationSeconds')), sample.get('cpuPercent', '-'), sample.get('memoryPercent', '-'), sample.get('temperatureC', '-'), sample.get('diskPercent', '-')])
            if len(rows) == 1:
                rows.append(['No log rows returned'] + ['-'] * 6)
            history = Table([[para(cell, styles['SmallX']) for cell in row] for row in rows], colWidths=[28*mm, 31*mm, 28*mm, 17*mm, 17*mm, 17*mm, 18*mm], repeatRows=1)
            history.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), NAVY), ('TEXTCOLOR', (0,0), (-1,0), colors.white), ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor('#D6E0E3')), ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, colors.HexColor('#F5F8F8')]), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 4), ('RIGHTPADDING', (0,0), (-1,-1), 4), ('TOPPADDING', (0,0), (-1,-1), 4), ('BOTTOMPADDING', (0,0), (-1,-1), 4)]))
            story += [Spacer(1, 7), para(f'Reboot and last-row monitoring history ({min(len(device.get("reboots", [])), 20)} rows shown)', styles['H2X']), history]
        story += [Spacer(1, 14)]
    doc.build(story, onFirstPage=footer, onLaterPages=footer)

if __name__ == '__main__':
    build_report(sys.argv[1], sys.argv[2])
