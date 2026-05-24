import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_utils.dart';

/// Reporte de cobros filtrado por cobrador.
/// Columnas: Fecha, Cliente, Monto (C$), Método, Recibo.
pw.Document buildReportePorCobrador({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required String cobradorNombre,
  required List<Map<String, dynamic>> rows,
}) {
  final pdf = pw.Document();

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: '$titulo — $cobradorNombre',
        periodo: periodo,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) => [
        _buildTable(rows),
        pw.SizedBox(height: 20),
        _buildTotals(rows),
      ],
    ),
  );

  return pdf;
}

pw.Widget _buildTable(List<Map<String, dynamic>> rows) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: {
      0: const pw.FlexColumnWidth(1.5),
      1: const pw.FlexColumnWidth(2.5),
      2: const pw.FlexColumnWidth(1.5),
      3: const pw.FlexColumnWidth(1.2),
      4: const pw.FlexColumnWidth(1.3),
    },
    headers: ['Fecha', 'Cliente', 'Monto (C\$)', 'Método', 'Recibo'],
    data: rows.isEmpty
        ? [['', 'Sin cobros en el período', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            return [
              _formatearFecha(r['fecha_pago'] as String? ?? ''),
              (r['cliente_nombre'] as String?) ?? '—',
              fmtCordobas((r['monto'] as num?) ?? 0),
              _metodoLabel((r['metodo'] as String?) ?? ''),
              (r['numero_recibo'] as String?) ?? '—',
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

pw.Widget _buildTotals(List<Map<String, dynamic>> rows) {
  final total = rows.fold<double>(
      0.0, (sum, r) => sum + ((r['monto'] as num?) ?? 0).toDouble());
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('Total: ${rows.length} cobro(s)', style: estiloTotal),
        pw.Text(fmtCordobas(total), style: estiloTotal),
      ],
    ),
  );
}

String _formatearFecha(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return fmtFechaCorta(d);
}

String _metodoLabel(String m) {
  switch (m.toLowerCase()) {
    case 'efectivo':
      return 'Efectivo';
    case 'transferencia':
      return 'Transfer.';
    case 'tarjeta':
      return 'Tarjeta';
    default:
      return m;
  }
}
