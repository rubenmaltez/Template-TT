import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_utils.dart';

/// Estado de cuenta individual de un cliente.
/// Header con datos del cliente + tabla de cuotas + tabla de pagos.
pw.Document buildEstadoCuenta({
  required String empresaNombre,
  required String clienteNombre,
  required String? clienteCedula,
  required String? clienteTelefono,
  required List<Map<String, dynamic>> cuotas,
  required List<Map<String, dynamic>> pagos,
}) {
  final pdf = pw.Document();

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      header: (context) => _buildHeader(
        empresaNombre: empresaNombre,
        clienteNombre: clienteNombre,
        clienteCedula: clienteCedula,
        clienteTelefono: clienteTelefono,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) => [
        pw.Text('Cuotas', style: estiloTitulo),
        pw.SizedBox(height: 8),
        _buildCuotasTable(cuotas),
        pw.SizedBox(height: 24),
        pw.Text('Historial de pagos', style: estiloTitulo),
        pw.SizedBox(height: 8),
        _buildPagosTable(pagos),
      ],
    ),
  );

  return pdf;
}

pw.Widget _buildHeader({
  required String empresaNombre,
  required String clienteNombre,
  required String? clienteCedula,
  required String? clienteTelefono,
}) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(empresaNombre, style: estiloEmpresa),
      pw.SizedBox(height: 4),
      pw.Text('Estado de cuenta', style: estiloTitulo),
      pw.SizedBox(height: 8),
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: PdfColors.grey100,
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(clienteNombre,
                      style: pw.TextStyle(
                          fontSize: 12, fontWeight: pw.FontWeight.bold)),
                  if (clienteCedula != null && clienteCedula.isNotEmpty)
                    pw.Text('Cédula: $clienteCedula', style: estiloCelda),
                  if (clienteTelefono != null && clienteTelefono.isNotEmpty)
                    pw.Text('Tel: $clienteTelefono', style: estiloCelda),
                ],
              ),
            ),
            pw.Text(
              'Generado: ${fmtFechaLarga(DateTime.now())}',
              style: estiloSubtitulo(),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 12),
    ],
  );
}

pw.Widget _buildCuotasTable(List<Map<String, dynamic>> cuotas) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: {
      0: const pw.FlexColumnWidth(2),
      1: const pw.FlexColumnWidth(1.5),
      2: const pw.FlexColumnWidth(1.5),
      3: const pw.FlexColumnWidth(1.5),
      4: const pw.FlexColumnWidth(1.5),
    },
    headers: ['Período', 'Vencimiento', 'Monto', 'Pagado', 'Estado'],
    data: cuotas.isEmpty
        ? [['Sin cuotas', '', '', '', '']]
        : List.generate(cuotas.length, (i) {
            final r = cuotas[i];
            return [
              (r['periodo'] as String?) ?? '—',
              _fmtFecha(r['fecha_vencimiento'] as String?),
              fmtCordobas((r['monto'] as num?) ?? 0),
              fmtCordobas((r['monto_pagado'] as num?) ?? 0),
              _estadoLabel((r['estado'] as String?) ?? ''),
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

pw.Widget _buildPagosTable(List<Map<String, dynamic>> pagos) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: {
      0: const pw.FlexColumnWidth(1.5),
      1: const pw.FlexColumnWidth(1.5),
      2: const pw.FlexColumnWidth(1.5),
      3: const pw.FlexColumnWidth(1.2),
      4: const pw.FlexColumnWidth(1.3),
    },
    headers: ['Fecha', 'Período', 'Monto (C\$)', 'Método', 'Recibo'],
    data: pagos.isEmpty
        ? [['Sin pagos registrados', '', '', '', '']]
        : List.generate(pagos.length, (i) {
            final r = pagos[i];
            return [
              _fmtFecha(r['fecha_pago'] as String?),
              (r['periodo'] as String?) ?? '—',
              fmtCordobas((r['monto_cordobas'] as num?) ?? 0),
              (r['metodo'] as String?) ?? '—',
              (r['numero_recibo'] as String?) ?? '—',
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

String _fmtFecha(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return fmtFechaCorta(d);
}

String _estadoLabel(String estado) {
  switch (estado) {
    case 'pendiente':
      return 'Pendiente';
    case 'parcial':
      return 'Parcial';
    case 'pagada':
      return 'Pagada';
    case 'vencida':
      return 'Vencida';
    case 'anulada':
      return 'Anulada';
    default:
      return estado;
  }
}
