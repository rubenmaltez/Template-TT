import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import '../../data/models/pago.dart';

// ---------------------------------------------------------------------------
// PDF generator del recibo — replica el ticket térmico (80mm o 57mm)
// en formato PDF descargable para web (admin). Coincide visualmente con
// el layout de `_ReciboTicket` y `_MultiReciboTicket`.
// ---------------------------------------------------------------------------

/// Ancho en puntos PDF según mm. 1 mm ≈ 2.8346 pt.
double _anchoPuntos(int mm) {
  if (mm == 57) return 161.57;
  // Default 80mm.
  return 226.77;
}

/// PDF para un recibo individual (cuota única).
///
/// [logoBytes] opcional: si se provee, se renderiza el logo de la empresa
/// centrado horizontalmente arriba del nombre de la empresa.
Future<pw.Document> buildReciboPdf({
  required Map<String, dynamic> row,
  required AppSettings settings,
  Uint8List? logoBytes,
}) async {
  final doc = pw.Document();
  final ancho = _anchoPuntos(settings.formatoReciboMm);

  final emision = DateTime.parse(row['fecha_pago'] as String);
  final periodoCuota = DateTime.parse(row['periodo'] as String);
  final diaPago = (row['dia_pago'] as num?)?.toInt();
  final esManual = row['plan_nombre'] == null;
  final periodoLabel = diaPago != null
      ? Fmt.periodoRecibo(diaPago, periodoCuota)
      : Fmt.mes(periodoCuota);

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(ancho, double.infinity,
          marginLeft: 8, marginRight: 8, marginTop: 12, marginBottom: 12),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          if (logoBytes != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Image(pw.MemoryImage(logoBytes),
                  height: 50, fit: pw.BoxFit.contain),
            ),
          if (settings.empresaNombre.isNotEmpty)
            pw.Text(
              settings.empresaNombre.toUpperCase(),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
              textAlign: pw.TextAlign.center,
            ),
          if (settings.empresaDireccion.isNotEmpty)
            pw.Text(settings.empresaDireccion,
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center),
          if (settings.empresaTelefono.isNotEmpty)
            pw.Text('Tel: ${settings.empresaTelefono}',
                style: const pw.TextStyle(fontSize: 8)),
          if (settings.empresaRuc.isNotEmpty)
            pw.Text('RUC: ${settings.empresaRuc}',
                style: const pw.TextStyle(fontSize: 8)),
          _pdfDivider(),

          _pdfRow('Recibo Nº', row['numero_completo'] as String),
          _pdfRow('Fecha', Fmt.fechaCorta(emision)),
          _pdfRow('Hora', Fmt.hora(emision)),
          _pdfRow('Cobrador', row['cobrador_nombre'] as String),
          _pdfDivider(),

          _pdfRow('Cliente', row['cliente_nombre'] as String),
          if (row['cliente_cedula'] != null)
            _pdfRow('Cédula', row['cliente_cedula'] as String),
          _pdfDivider(),

          _pdfRow(
              'Servicio',
              esManual
                  ? (row['cuota_descripcion'] as String? ?? 'Cuota manual')
                  : row['plan_nombre'] as String),
          _pdfRow('Período',
              periodoLabel[0].toUpperCase() + periodoLabel.substring(1)),
          _pdfRow('Cuota base', Fmt.cordobas(row['cuota_monto'] as num)),

          if (settings.reciboMontoEnLetras)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              child: pw.Text(
                montoALetras(
                  (row['monto_cordobas'] as num).toDouble(),
                  moneda: (row['moneda'] as String?) ?? 'NIO',
                ),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                    fontSize: 7, fontWeight: pw.FontWeight.bold),
              ),
            ),

          _pdfDivider(),

          _pdfRow(
              'Método',
              MetodoPago.fromString(row['metodo'] as String)
                  .label
                  .toUpperCase()),
          if (row['referencia'] != null)
            _pdfRow('Ref.', row['referencia'] as String),
          if ((row['moneda'] as String) == 'USD')
            _pdfRow(
              'Recibido',
              'US\$${(row['monto_original'] as num).toStringAsFixed(2)} '
                  '(tasa ${(row['tasa_conversion'] as num).toStringAsFixed(2)})',
            ),
          pw.SizedBox(height: 6),
          // COBRADO = monto aplicado a la cuota (lo que entra a la caja).
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('COBRADO',
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 11)),
              pw.Text(
                Fmt.cordobas(row['monto_cordobas'] as num),
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11),
              ),
            ],
          ),
          // VUELTO + PAGADO si hubo vuelto.
          ..._vueltoIfNeeded(row),

          if (settings.pieRecibo.isNotEmpty) ...[
            _pdfDivider(),
            pw.Text(settings.pieRecibo,
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center),
          ],

          pw.SizedBox(height: 6),
          if (row['impreso_en'] != null)
            pw.Text(
              'Reimpresión #${(row['reimpresiones'] as int? ?? 0) + 1}',
              style:
                  const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
            ),
        ],
      ),
    ),
  );
  return doc;
}

/// PDF para cobro múltiple (varios pagos agrupados).
///
/// [logoBytes] opcional: si se provee, se renderiza el logo de la empresa
/// centrado horizontalmente arriba del nombre de la empresa.
Future<pw.Document> buildMultiReciboPdf({
  required List<Map<String, dynamic>> rows,
  required AppSettings settings,
  Uint8List? logoBytes,
}) async {
  final doc = pw.Document();
  final ancho = _anchoPuntos(settings.formatoReciboMm);
  final first = rows.first;
  final emision = DateTime.parse(first['fecha_pago'] as String);
  var totalCobrado = 0.0;
  var totalVuelto = 0.0;
  for (final r in rows) {
    totalCobrado += (r['monto_cordobas'] as num).toDouble();
    totalVuelto += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
  }
  final totalEntregado = totalCobrado + totalVuelto;

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(ancho, double.infinity,
          marginLeft: 8, marginRight: 8, marginTop: 12, marginBottom: 12),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          if (logoBytes != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Image(pw.MemoryImage(logoBytes),
                  height: 50, fit: pw.BoxFit.contain),
            ),
          if (settings.empresaNombre.isNotEmpty)
            pw.Text(
              settings.empresaNombre.toUpperCase(),
              style:
                  pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
              textAlign: pw.TextAlign.center,
            ),
          if (settings.empresaDireccion.isNotEmpty)
            pw.Text(settings.empresaDireccion,
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center),
          if (settings.empresaTelefono.isNotEmpty)
            pw.Text('Tel: ${settings.empresaTelefono}',
                style: const pw.TextStyle(fontSize: 8)),
          if (settings.empresaRuc.isNotEmpty)
            pw.Text('RUC: ${settings.empresaRuc}',
                style: const pw.TextStyle(fontSize: 8)),
          _pdfDivider(),

          pw.Text('COBRO MÚLTIPLE (${rows.length} cuotas)',
              style:
                  pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
          pw.SizedBox(height: 4),
          _pdfRow('Recibos',
              '${rows.first['numero_completo']} - ${rows.last['numero_completo']}'),
          _pdfRow('Fecha', Fmt.fechaCorta(emision)),
          _pdfRow('Hora', Fmt.hora(emision)),
          _pdfRow('Cobrador', first['cobrador_nombre'] as String),
          _pdfDivider(),

          _pdfRow('Cliente', first['cliente_nombre'] as String),
          if (first['cliente_cedula'] != null)
            _pdfRow('Cédula', first['cliente_cedula'] as String),
          _pdfDivider(),

          for (final r in rows)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      '${Fmt.mes(DateTime.parse(r['periodo'] as String))[0].toUpperCase()}'
                      '${Fmt.mes(DateTime.parse(r['periodo'] as String)).substring(1)}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ),
                  pw.Text(Fmt.cordobas(r['monto_cordobas'] as num),
                      style: const pw.TextStyle(fontSize: 8)),
                ],
              ),
            ),

          _pdfDivider(),
          _pdfRow(
              'Método',
              MetodoPago.fromString(first['metodo'] as String)
                  .label
                  .toUpperCase()),
          if (first['referencia'] != null)
            _pdfRow('Ref.', first['referencia'] as String),

          if (settings.reciboMontoEnLetras)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              child: pw.Text(
                // Monto en letras = COBRADO (lo que entró a caja).
                montoALetras(totalCobrado,
                    moneda: (first['moneda'] as String?) ?? 'NIO'),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                    fontSize: 7, fontWeight: pw.FontWeight.bold),
              ),
            ),

          pw.SizedBox(height: 6),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('TOTAL COBRADO',
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 11)),
              pw.Text(Fmt.cordobas(totalCobrado),
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 11)),
            ],
          ),
          if (totalVuelto > 0.01) ...[
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('VUELTO',
                      style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 9)),
                  pw.Text(Fmt.cordobas(totalVuelto),
                      style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 9)),
                ],
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 2),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('PAGADO',
                      style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.Text(Fmt.cordobas(totalEntregado),
                      style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 10)),
                ],
              ),
            ),
          ],

          if (settings.pieRecibo.isNotEmpty) ...[
            _pdfDivider(),
            pw.Text(settings.pieRecibo,
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center),
          ],
        ],
      ),
    ),
  );
  return doc;
}

// ---------------------------------------------------------------------------
// Helpers internos
// ---------------------------------------------------------------------------

pw.Widget _pdfRow(String label, String value) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 60,
          child: pw.Text('$label:', style: const pw.TextStyle(fontSize: 8)),
        ),
        pw.Expanded(
          child: pw.Text(value,
              textAlign: pw.TextAlign.right,
              style: const pw.TextStyle(fontSize: 8)),
        ),
      ],
    ),
  );
}

pw.Widget _pdfDivider() => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Container(
          height: 0.5, width: double.infinity, color: PdfColors.grey700),
    );

List<pw.Widget> _vueltoIfNeeded(Map<String, dynamic> row) {
  // Lee el vuelto del pago directamente (columna vuelto_cordobas).
  // Defensivo para rows legacy (pre-migración 0061): 0 si no existe.
  // Regla de negocio: el vuelto SIEMPRE se da en córdobas, incluso si
  // el cliente pagó en USD. El label refleja eso para evitar confusión.
  final vuelto = (row['vuelto_cordobas'] as num? ?? 0).toDouble();
  if (vuelto <= 0.01) return const [];
  final cobrado = (row['monto_cordobas'] as num).toDouble();
  final entregado = cobrado + vuelto;
  final esUsd = (row['moneda'] as String) == 'USD';
  final pagadoLabel = esUsd
      ? 'US\$${(row['monto_original'] as num).toStringAsFixed(2)} = ${Fmt.cordobas(entregado)}'
      : Fmt.cordobas(entregado);
  return [
    pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 9)),
          pw.Text(Fmt.cordobas(vuelto),
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 9)),
        ],
      ),
    ),
    pw.Padding(
      padding: const pw.EdgeInsets.only(top: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('PAGADO',
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 10)),
          pw.Text(pagadoLabel,
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 10)),
        ],
      ),
    ),
  ];
}
