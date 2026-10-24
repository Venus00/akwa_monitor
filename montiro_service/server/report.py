import json
import os
import sys
from datetime import datetime, timezone
try:
    from zoneinfo import ZoneInfo
    REPORT_ZONE = ZoneInfo('Africa/Casablanca')
except Exception:
    REPORT_ZONE = timezone.utc
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
from reportlab.platypus import Image

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
        return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(REPORT_ZONE).strftime('%Y-%m-%d %H:%M:%S')
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

def build_report(source, output, logo_path=None):
    with open(source, encoding='utf-8') as stream:
        payload = json.load(stream)
    devices = payload.get('devices', [])
    online = sum(device.get('status') == 'online' for device in devices)
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name='TitleX', parent=styles['Title'], fontName='Helvetica-Bold', fontSize=26, leading=30, textColor=colors.white))
    styles.add(ParagraphStyle(name='SubX', parent=styles['Normal'], fontSize=9, leading=13, textColor=colors.HexColor('#B8D5CF')))
    styles.add(ParagraphStyle(name='TitleDark', parent=styles['Title'], fontName='Helvetica-Bold', fontSize=25, leading=29, textColor=NAVY))
    styles.add(ParagraphStyle(name='SubDark', parent=styles['Normal'], fontSize=9, leading=13, textColor=MUTED))
    styles.add(ParagraphStyle(name='H1X', parent=styles['Heading1'], fontName='Helvetica-Bold', fontSize=16, leading=20, textColor=NAVY, spaceBefore=10, spaceAfter=8))
    styles.add(ParagraphStyle(name='H2X', parent=styles['Heading2'], fontName='Helvetica-Bold', fontSize=11, leading=14, textColor=TEAL, spaceBefore=7, spaceAfter=4))
    styles.add(ParagraphStyle(name='BodyX', parent=styles['BodyText'], fontSize=9, leading=13, textColor=INK, spaceAfter=5))
    styles.add(ParagraphStyle(name='SmallX', parent=styles['BodyText'], fontSize=7.2, leading=9.5, textColor=MUTED))
    styles.add(ParagraphStyle(name='WhiteX', parent=styles['BodyText'], fontSize=9, leading=12, textColor=colors.white))
    doc = SimpleDocTemplate(output, pagesize=A4, rightMargin=18*mm, leftMargin=18*mm, topMargin=16*mm, bottomMargin=20*mm, title='AKWA Factory Test Report', author='AKWA Monitoring')
    story = []
    report_id = datetime.now().strftime('AKWA-%Y%m%d-%H%M%S')
    logo_cell = Image(logo_path, width=28*mm, height=12*mm, kind='proportional') if logo_path and os.path.isfile(logo_path) else para('FMC2E', styles['SubX'])
    header = Table([[logo_cell, para('RAPPORT DE RECEPTION ET DE DIAGNOSTIC - CARTES HARDIOTM7', styles['TitleDark'])], [para('Client : AKWA', styles['SubDark']), para('Analyse retour terrain, tests fonctionnels et diagnostic noyau', styles['SubDark'])], [para('', styles['SubDark']), para(f'Reference : {report_id}<br/>Date du rapport : {date_text(payload.get("generatedAt"))}', styles['SubDark'])]], colWidths=[35*mm, 139*mm])
    header.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,-1), colors.white), ('BOX', (0,0), (-1,-1), 0.7, colors.HexColor('#D9E2E5')), ('LINEBELOW', (0,0), (-1,0), 1.2, TEAL), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 12), ('RIGHTPADDING', (0,0), (-1,-1), 12), ('TOPPADDING', (0,0), (-1,-1), 11), ('BOTTOMPADDING', (0,0), (-1,-1), 11)]))
    story += [header, Spacer(1, 12)]
    summary = Table([[para('CARTES TESTEES', styles['SmallX']), para('EN LIGNE', styles['SmallX']), para('HORS LIGNE', styles['SmallX']), para('SOURCES ANALYSEES', styles['SmallX'])], [para(len(devices), styles['H1X']), para(online, styles['H1X']), para(len(devices)-online, styles['H1X']), para('SSH / seconde / dmesg / journalctl -k', styles['SmallX'])]], colWidths=[35*mm, 30*mm, 30*mm, 79*mm])
    summary.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,-1), PALE), ('BOX', (0,0), (-1,-1), 0.5, colors.HexColor('#B9DCD3')), ('VALIGN', (0,0), (-1,-1), 'MIDDLE'), ('LEFTPADDING', (0,0), (-1,-1), 9), ('RIGHTPADDING', (0,0), (-1,-1), 9), ('TOPPADDING', (0,0), (-1,-1), 8), ('BOTTOMPADDING', (0,0), (-1,-1), 8)]))
    story += [summary, Spacer(1, 14), para('Objet et perimetre du diagnostic', styles['H1X']), para('Ce rapport documente la reception et l\'analyse des cartes HARDIOTM7 AKWA retournees apres un incident constate sur le terrain. Les tests portent sur l\'accessibilite SSH, la duree de fonctionnement, l\'historique des redemarrages, les mesures de supervision et les alertes noyau critiques lues avec dmesg et journalctl -k. Les cartes inaccessibles sont marquees hors ligne et leurs mesures ainsi que leurs journaux noyau sont indiquees comme indisponibles.', styles['BodyX']), para('Controles de diagnostic', styles['H2X'])]
    checks = [['Controle', 'Methode', 'Preuve d\'acceptation'], ['Reseau et SSH', 'Ouvrir une session SSH avec les identifiants serveur configures.', 'La carte retourne une reponse.'], ['Duree de fonctionnement', 'Lire /proc/uptime sur la carte.', 'La duree est presente et positive.'], ['Historique des redemarrages', 'Lister les CSV de demarrage et lire la derniere ligne de chaque fichier.', 'Chaque fichier fournit un UUID et une date de redemarrage derivee.'], ['Supervision', 'Lire la derniere ligne delimitee par des points-virgules de chaque CSV.', 'Date, duree, CPU, memoire, temperature et disque sont captures.'], ['Alertes noyau critiques', 'Lire dmesg et journalctl -k puis filtrer les pannes fatales ou dangereuses.', 'Seuls les messages critiques sont affiches.']]
    check_table = Table([[para(cell, styles['SmallX']) for cell in row] for row in checks], colWidths=[31*mm, 72*mm, 71*mm], repeatRows=1)
    check_table.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), NAVY), ('TEXTCOLOR', (0,0), (-1,0), colors.white), ('GRID', (0,0), (-1,-1), 0.35, colors.HexColor('#D6E0E3')), ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, colors.HexColor('#F5F8F8')]), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 7), ('RIGHTPADDING', (0,0), (-1,-1), 7), ('TOPPADDING', (0,0), (-1,-1), 6), ('BOTTOMPADDING', (0,0), (-1,-1), 6)]))
    story += [check_table, PageBreak(), para('Board-by-board results', styles['H1X'])]
    for index, device in enumerate(devices):
        state = 'VALIDE - EN LIGNE' if device.get('status') == 'online' else 'ECHEC - HORS LIGNE'
        state_style = ParagraphStyle(f'state{index}', parent=styles['SmallX'], textColor=TEAL if device.get('status') == 'online' else RED, alignment=2)
        title = Table([[para(f'{index+1:02d}  {device.get("name", "Unknown")}', styles['H2X']), para(state, state_style)]], colWidths=[120*mm, 54*mm])
        title.setStyle(TableStyle([('LINEBELOW', (0,0), (-1,-1), 0.7, colors.HexColor('#D6E0E3')), ('VALIGN', (0,0), (-1,-1), 'BOTTOM')]))
        story += [title, para(f'Etiquette : {device.get("tag", "CARTE")} | Adresse IP : {device.get("ip", "-")} | Adresse MAC : {device.get("mac", "-")} | Nom machine : {device.get("hostname", "-")}', styles['SmallX'])]
        overview = [['Duree actuelle', 'Dernier UUID de demarrage', 'Latence', 'Controle effectue'], [duration(device.get('uptimeSeconds')), device.get('latestBoot') or '-', f'{device.get("latencyMs", "-")} ms', date_text(device.get('checkedAt'))]]
        overview_table = Table([[para(cell, styles['SmallX']) for cell in row] for row in overview], colWidths=[43*mm, 50*mm, 31*mm, 50*mm])
        overview_table.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), PALE), ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor('#D6E0E3')), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 6), ('RIGHTPADDING', (0,0), (-1,-1), 6), ('TOPPADDING', (0,0), (-1,-1), 5), ('BOTTOMPADDING', (0,0), (-1,-1), 5)]))
        story += [Spacer(1, 6), overview_table]
        if device.get('error'):
            story += [Spacer(1, 5), para(f'Resultat de connexion : {device["error"]}', styles['SmallX']), para('Alertes noyau critiques - dmesg et journalctl : non capturees car la carte est inaccessible.', styles['SmallX'])]
        else:
            rows = [['Redemarrage derive', 'Derniere mesure', 'Duree', 'CPU', 'RAM', 'Temp.', 'Disque']]
            for reboot in device.get('reboots', [])[:20]:
                sample = reboot.get('sample') or {}
                rows.append([date_text(reboot.get('rebootAt')), date_text(sample.get('at')), duration(sample.get('durationSeconds')), sample.get('cpuPercent', '-'), sample.get('memoryPercent', '-'), sample.get('temperatureC', '-'), sample.get('diskPercent', '-')])
            if len(rows) == 1:
                rows.append(['Aucune ligne de journal retournee'] + ['-'] * 6)
            history = Table([[para(cell, styles['SmallX']) for cell in row] for row in rows], colWidths=[28*mm, 31*mm, 28*mm, 17*mm, 17*mm, 17*mm, 18*mm], repeatRows=1)
            history.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), NAVY), ('TEXTCOLOR', (0,0), (-1,0), colors.white), ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor('#D6E0E3')), ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, colors.HexColor('#F5F8F8')]), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 4), ('RIGHTPADDING', (0,0), (-1,-1), 4), ('TOPPADDING', (0,0), (-1,-1), 4), ('BOTTOMPADDING', (0,0), (-1,-1), 4)]))
            story += [Spacer(1, 7), para(f'Historique des redemarrages et des dernieres mesures ({min(len(device.get("reboots", [])), 20)} lignes affichees)', styles['H2X']), history]
            kernel_logs = device.get('kernelLogs', {})
            dmesg_errors = kernel_logs.get('dmesg', [])
            journal_errors = kernel_logs.get('journal', [])
            kernel_rows = [[para('Source', styles['SmallX']), para('Alertes noyau critiques ou dangereuses', styles['SmallX'])]]
            kernel_rows += [[para('dmesg', styles['SmallX']), para(message, styles['SmallX'])] for message in (dmesg_errors[-30:] if dmesg_errors else ['Aucune alerte critique retournee par dmesg.'])]
            kernel_rows += [[para('journalctl -k', styles['SmallX']), para(message, styles['SmallX'])] for message in (journal_errors[-30:] if journal_errors else ['Aucune alerte critique retournee par le journal noyau.'])]
            kernel_table = Table(kernel_rows, colWidths=[30*mm, 144*mm], repeatRows=1)
            kernel_table.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), NAVY), ('TEXTCOLOR', (0,0), (-1,0), colors.white), ('GRID', (0,0), (-1,-1), 0.3, colors.HexColor('#D6E0E3')), ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, colors.HexColor('#F5F8F8')]), ('VALIGN', (0,0), (-1,-1), 'TOP'), ('LEFTPADDING', (0,0), (-1,-1), 6), ('RIGHTPADDING', (0,0), (-1,-1), 6), ('TOPPADDING', (0,0), (-1,-1), 4), ('BOTTOMPADDING', (0,0), (-1,-1), 4)]))
            story += [Spacer(1, 7), para(f'Alertes noyau critiques - dmesg et journalctl ({len(dmesg_errors) + len(journal_errors)} messages capturees)', styles['H2X']), kernel_table]
        story += [Spacer(1, 14)]
    doc.build(story, onFirstPage=footer, onLaterPages=footer)

if __name__ == '__main__':
    build_report(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
