import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de clientes con estado de cuenta.
/// Columnas: Cliente, Comunidad, Cuotas pendientes, Saldo, Último pago.
Future<pw.Document> buildReporteClientes({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required List<Map<String, dynamic>> rows,
}) async {
  final pdf = pw.Document();
  final theme = await pdfTheme();

  pdf.addPage(
    pw.MultiPage(
      theme: theme,
      pageFormat: PdfPageFormat.letter,
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: titulo,
        periodo: periodo,
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) => [
        _buildTable(rows),
        pw.SizedBox(height: 20),
        _buildSummary(rows),
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
      0: const pw.FlexColumnWidth(2.5),
      1: const pw.FlexColumnWidth(2),
      2: const pw.FlexColumnWidth(1.3),
      3: const pw.FlexColumnWidth(1.5),
      4: const pw.FlexColumnWidth(1.5),
    },
    headers: ['Cliente', 'Comunidad', 'Pendientes', 'Saldo (C\$)', 'Último pago'],
    data: rows.isEmpty
        ? [['Sin clientes', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final ultimoPago = r['ultimo_pago'] as String?;
            return [
              (r['nombre'] as String?) ?? '—',
              (r['comunidad'] as String?) ?? '—',
              '${(r['pendientes'] as num?) ?? 0}',
              fmtCordobas((r['saldo'] as num?) ?? 0),
              ultimoPago != null ? _formatearFecha(ultimoPago) : 'Sin pagos',
            ];
          }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

pw.Widget _buildSummary(List<Map<String, dynamic>> rows) {
  final totalSaldo = rows.fold<double>(
      0.0, (sum, r) => sum + ((r['saldo'] as num?) ?? 0).toDouble());
  final totalPendientes = rows.fold<int>(
      0, (sum, r) => sum + ((r['pendientes'] as num?) ?? 0).toInt());
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('${rows.length} clientes · $totalPendientes cuotas pendientes',
            style: estiloTotal),
        pw.Text('Saldo total: ${fmtCordobas(totalSaldo)}', style: estiloTotal),
      ],
    ),
  );
}

String _formatearFecha(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return fmtFechaCorta(d);
}
