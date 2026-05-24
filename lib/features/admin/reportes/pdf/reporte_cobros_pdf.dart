import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_utils.dart';

/// Genera un PDF de "Reporte de cobros" con los datos proporcionados.
///
/// Parámetros:
///   - [titulo]: ej "Reporte de cobros — Mayo 2026"
///   - [rows]: lista de Maps con keys: fecha_pago, cliente_nombre, monto,
///     metodo, cobrador_nombre, numero_recibo
///   - [empresaNombre]: nombre del ISP para el header
///   - [periodo]: texto descriptivo del período
///
/// Retorna el Document PDF listo para imprimir/descargar.
pw.Document buildReporteCobros({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required List<Map<String, dynamic>> rows,
}) {
  final pdf = pw.Document();

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.all(40),
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: titulo,
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

// ---------------------------------------------------------------------------
// Tabla de cobros
// ---------------------------------------------------------------------------

pw.Widget _buildTable(List<Map<String, dynamic>> rows) {
  return pw.TableHelper.fromTextArray(
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    headerDecoration: const pw.BoxDecoration(color: colorHeaderTabla),
    headerStyle: estiloColumna,
    cellStyle: estiloCelda,
    headerAlignment: pw.Alignment.centerLeft,
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: {
      0: const pw.FlexColumnWidth(1.5), // Fecha
      1: const pw.FlexColumnWidth(2.5), // Cliente
      2: const pw.FlexColumnWidth(1.5), // Monto
      3: const pw.FlexColumnWidth(1.2), // Método
      4: const pw.FlexColumnWidth(2),   // Cobrador
      5: const pw.FlexColumnWidth(1.3), // Recibo
    },
    headers: ['Fecha', 'Cliente', 'Monto', 'Método', 'Cobrador', 'Recibo'],
    data: List.generate(rows.length, (i) {
      final r = rows[i];
      final fecha = r['fecha_pago'] as String? ?? '';
      final fechaFmt = _formatearFecha(fecha);
      return [
        fechaFmt,
        (r['cliente_nombre'] as String?) ?? '—',
        fmtCordobas((r['monto'] as num?) ?? 0),
        _metodoLabel((r['metodo'] as String?) ?? ''),
        (r['cobrador_nombre'] as String?) ?? '—',
        (r['numero_recibo'] as String?) ?? '—',
      ];
    }),
    oddRowDecoration: const pw.BoxDecoration(color: colorFilaPar),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  );
}

// ---------------------------------------------------------------------------
// Totales
// ---------------------------------------------------------------------------

pw.Widget _buildTotals(List<Map<String, dynamic>> rows) {
  final totalMonto = rows.fold<double>(
    0,
    (sum, r) => sum + ((r['monto'] as num?) ?? 0).toDouble(),
  );
  final cantCobros = rows.length;

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.blueGrey50,
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('Total: $cantCobros cobros', style: estiloTotal),
        pw.Text('Monto total: ${fmtCordobas(totalMonto)}', style: estiloTotal),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Helpers internos
// ---------------------------------------------------------------------------

/// Convierte "2026-05-24" o "2026-05-24T14:30:00" → "24/05/2026".
String _formatearFecha(String raw) {
  final dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  return fmtFechaCorta(dt);
}

/// Traduce el código de método de pago a label legible.
String _metodoLabel(String metodo) {
  switch (metodo) {
    case 'efectivo':
      return 'Efectivo';
    case 'transferencia':
      return 'Transfer.';
    case 'tarjeta':
      return 'Tarjeta';
    default:
      return metodo.isNotEmpty
          ? metodo[0].toUpperCase() + metodo.substring(1)
          : '—';
  }
}
