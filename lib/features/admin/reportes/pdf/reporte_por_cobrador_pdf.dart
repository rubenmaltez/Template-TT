import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../data/models/pago.dart';
import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de cobros filtrado por cobrador.
/// Columnas: Fecha, Cliente, Monto (C$), Método, Recibo.
Future<pw.Document> buildReportePorCobrador({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required String cobradorNombre,
  required List<Map<String, dynamic>> rows,
  Uint8List? logoBytes,
}) async {
  final pdf = pw.Document();
  final theme = await pdfTheme();
  final logo = logoBytes == null ? null : pw.MemoryImage(logoBytes);

  pdf.addPage(
    pw.MultiPage(
      theme: theme,
      // Landscape: columnas extra de moneda/tasa/vuelto no entran en vertical.
      pageFormat: PdfPageFormat.letter.landscape,
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: '$titulo — $cobradorNombre',
        periodo: periodo,
        logo: logo,
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
      0: const pw.FlexColumnWidth(1.4), // Fecha
      1: const pw.FlexColumnWidth(2.3), // Cliente
      2: const pw.FlexColumnWidth(1.4), // Monto cobrado (C$)
      3: const pw.FlexColumnWidth(0.9), // Moneda
      4: const pw.FlexColumnWidth(1.3), // Entregado (orig.)
      5: const pw.FlexColumnWidth(0.9), // Tasa
      6: const pw.FlexColumnWidth(1.2), // Vuelto (C$)
      7: const pw.FlexColumnWidth(1.2), // Método
      8: const pw.FlexColumnWidth(1.3), // Recibo
    },
    headers: ['Fecha de cobro', 'Cliente', 'Monto cobrado (C\$)',
        'Moneda', 'Entregado (orig.)', 'Tasa', 'Vuelto (C\$)',
        'Método de pago', 'Nro. de recibo'],
    data: rows.isEmpty
        ? [['', 'Sin cobros en el período', '', '', '', '', '', '', '']]
        : List.generate(rows.length, (i) {
            final r = rows[i];
            final moneda = r['moneda'] as String?;
            final esUsd = moneda == 'USD';
            final vuelto = ((r['vuelto_cordobas'] as num?) ?? 0).toDouble();
            return [
              _formatearFecha(r['fecha_pago'] as String? ?? ''),
              (r['cliente_nombre'] as String?) ?? '—',
              fmtCordobas((r['monto'] as num?) ?? 0),
              monedaSimbolo(moneda),
              fmtMontoMoneda((r['monto_original'] as num?) ?? 0, moneda),
              esUsd
                  ? ((r['tasa_conversion'] as num?) ?? 1).toStringAsFixed(2)
                  : '—',
              vuelto > 0 ? fmtCordobas(vuelto) : '—',
              MetodoPago.fromString((r['metodo'] as String?) ?? '').label,
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
  // fecha_pago es hora local Nicaragua (wall-clock): formatear directo, sin
  // shift de TZ. Coincide con el recibo y con el bucket date(fecha_pago).
  return fmtFechaCorta(d);
}
