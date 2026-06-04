import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/models/recibo_layout.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';
import '../../data/models/pago.dart';
import '../shared/pdf/pdf_theme.dart';

// ---------------------------------------------------------------------------
// PDF generator del recibo — replica el ticket térmico (80mm o 58mm)
// en formato PDF descargable para web (admin) Y como fuente del raster que
// imprime la térmica (rasterizando este PDF). Coincide visualmente con
// el layout de `_ReciboTicket` y `_MultiReciboTicket`.
// ---------------------------------------------------------------------------

/// Ancho en puntos PDF según mm. 1 mm ≈ 2.8346 pt.
double _anchoPuntos(int mm) {
  // Cualquier ancho que NO sea 80mm se trata como 58mm (≈ 164.4 pt). El único
  // formato chico soportado es 58mm; valores legacy (57) caen acá igual.
  if (mm != 80) return 164.4;
  // Default 80mm.
  return 226.77;
}

/// PDF para un recibo individual (cuota única).
///
/// [logoBytes] opcional: si se provee, se renderiza el logo de la empresa
/// centrado horizontalmente arriba del nombre de la empresa.
///
/// [moraRows] = detalle de mora del contrato YA filtrado por el call-site
/// (excluida la cuota cobrada). Estas funciones no tienen `ref` ni hacen IO,
/// así que la mora se calcula afuera (`fetchMoraContrato`) y se pasa hecha.
/// Vacío → el bloque `mora` no se muestra.
Future<pw.Document> buildReciboPdf({
  required Map<String, dynamic> row,
  required AppSettings settings,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
}) async {
  final doc = pw.Document();
  final theme = await pdfTheme();
  final ancho = _anchoPuntos(settings.formatoReciboMm);

  // Se ITERA el layout configurable: cada bloque se construye en
  // `_pdfBloqueSingle` (devuelve [] si no hay nada que mostrar) y entre bloques
  // se emite SOLO espaciado (sin líneas de separación) — estilo limpio: las
  // secciones se distinguen por aire + negritas. Gap chico entre dos bloques
  // de header (van más juntos), gap mayor en el resto. El contenido/orden lo
  // manda `settings.reciboLayout`; el bloque `totales` (dinero) sigue intacto.
  final children = <pw.Widget>[];
  String? zonaPrev;
  for (final b in settings.reciboLayout) {
    if (!b.visible) continue;
    final contenido = _pdfBloqueSingle(b.id, _pdfScale(b.size), row, settings,
        logoBytes: logoBytes, moraRows: moraRows);
    if (contenido.isEmpty) continue;
    final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
    if (children.isNotEmpty) {
      if (zonaPrev == 'header' && zona == ReciboZona.header) {
        children.add(pw.SizedBox(height: 2));
      } else {
        children.add(pw.SizedBox(height: 6));
      }
    }
    children.addAll(contenido);
    zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
  }

  // Badge de reimpresión: NO es un bloque del layout, va SIEMPRE al final.
  if (row['impreso_en'] != null) {
    children.add(pw.SizedBox(height: 6));
    children.add(pw.Text(
      'Reimpresión #${(row['reimpresiones'] as int? ?? 0) + 1}',
      style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
    ));
  }

  doc.addPage(
    pw.Page(
      theme: theme,
      pageFormat: PdfPageFormat(ancho, double.infinity,
          marginLeft: 8, marginRight: 8, marginTop: 12, marginBottom: 12),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: children,
      ),
    ),
  );
  return doc;
}

/// Multiplicador de fontSize del bloque (chico/normal/grande) para el PDF.
/// Mismos factores que pantalla → consistencia entre los 3 renderers.
double _pdfScale(ReciboTextoSize s) => switch (s) {
      ReciboTextoSize.chico => 0.85,
      ReciboTextoSize.grande => 1.3,
      ReciboTextoSize.normal => 1.0,
    };

/// Construye las líneas de UN bloque del recibo single en PDF. Devuelve [] si
/// el bloque no tiene nada que mostrar (logo null, empresa vacía, pie vacío…).
List<pw.Widget> _pdfBloqueSingle(
  String id,
  double k,
  Map<String, dynamic> row,
  AppSettings settings, {
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
}) {
  switch (id) {
    case 'logo':
      if (logoBytes == null) return const [];
      return [
        pw.Image(pw.MemoryImage(logoBytes),
            height: 50 * k, fit: pw.BoxFit.contain),
      ];
    case 'empresa':
      final out = <pw.Widget>[];
      if (settings.empresaNombre.isNotEmpty) {
        out.add(pw.Text(
          settings.empresaNombre.toUpperCase(),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11 * k),
          textAlign: pw.TextAlign.center,
        ));
      }
      if (settings.empresaDireccion.isNotEmpty) {
        out.add(pw.Text(settings.empresaDireccion,
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center));
      }
      if (settings.empresaTelefono.isNotEmpty) {
        out.add(pw.Text('Tel: ${settings.empresaTelefono}',
            style: pw.TextStyle(fontSize: 8 * k)));
      }
      if (settings.empresaRuc.isNotEmpty) {
        out.add(pw.Text('RUC: ${settings.empresaRuc}',
            style: pw.TextStyle(fontSize: 8 * k)));
      }
      return out;
    case 'titulo':
      if (settings.reciboTitulo.isEmpty) return const [];
      return [
        pw.Text(
          settings.reciboTitulo.toUpperCase(),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k),
          textAlign: pw.TextAlign.center,
        ),
      ];
    case 'meta':
      final emision = DateTime.parse(row['fecha_pago'] as String);
      return [
        _pdfRow('Recibo Nº', row['numero_completo'] as String, k),
        _pdfRow('Fecha', Fmt.fechaCorta(emision), k),
        _pdfRow('Hora', Fmt.hora(emision), k),
        _pdfRow('Cobrador', row['cobrador_nombre'] as String, k),
      ];
    case 'cliente':
      return [
        _pdfRow('Cliente', row['cliente_nombre'] as String, k),
        if (settings.reciboMostrarCedula && row['cliente_cedula'] != null)
          _pdfRow('Cédula', row['cliente_cedula'] as String, k),
      ];
    case 'servicio':
      final periodoCuota = DateTime.parse(row['periodo'] as String);
      final diaPago = (row['dia_pago'] as num?)?.toInt();
      final esManual = row['plan_nombre'] == null;
      final periodoLabel = diaPago != null
          ? Fmt.periodoRecibo(diaPago, periodoCuota)
          : Fmt.mes(periodoCuota);
      return [
        _pdfRow(
            'Servicio',
            esManual
                ? (row['cuota_descripcion'] as String? ?? 'Cuota manual')
                : row['plan_nombre'] as String,
            k),
        _pdfRow('Período',
            periodoLabel[0].toUpperCase() + periodoLabel.substring(1), k),
      ];
    case 'cuota':
      // Saldo de la cuota tras este pago (sub-toggle `mostrar_adeudado`).
      final saldoCuota = ((row['cuota_monto'] as num).toDouble() +
              (row['cargos_neto'] as num? ?? 0).toDouble()) -
          (row['monto_pagado_cuota'] as num? ?? row['monto_cordobas'] as num)
              .toDouble();
      return [
        _pdfRow('Cuota base', Fmt.cordobas(row['cuota_monto'] as num), k),
        if (settings.reciboMostrarAdeudado && saldoCuota > 0.01)
          _pdfRow('Saldo cuota', Fmt.cordobas(saldoCuota), k),
      ];
    case 'metodo':
      return [
        _pdfRow(
            'Método',
            MetodoPago.fromString(row['metodo'] as String).label.toUpperCase(),
            k),
        if (row['referencia'] != null)
          _pdfRow('Ref.', row['referencia'] as String, k),
        if ((row['moneda'] as String) == 'USD')
          _pdfRow(
            'Recibido',
            'US\$${(row['monto_original'] as num).toStringAsFixed(2)} '
                '(tasa ${(row['tasa_conversion'] as num).toStringAsFixed(2)})',
            k,
          ),
      ];
    case 'letras':
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Text(
            montoALetras(
              (row['monto_cordobas'] as num).toDouble(),
              moneda: (row['moneda'] as String?) ?? 'NIO',
            ),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 7 * k, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ];
    case 'totales':
      // EL BLOQUE DE DINERO. Matemática y contenido IDÉNTICOS al original:
      // COBRADO siempre, + VUELTO/PAGADO si hubo vuelto (con manejo USD).
      // Solo cambió su posición (la da el layout).
      return [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('COBRADO',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k)),
            pw.Text(
              Fmt.cordobas(row['monto_cordobas'] as num),
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 11 * k),
            ),
          ],
        ),
        // VUELTO + PAGADO si hubo vuelto.
        ..._vueltoIfNeeded(row, k),
      ];
    case 'mora':
      // Detalle de mora del contrato (ya filtrado por el call-site). Resumen
      // informativo de lo que el cliente aún debe — no toca la matemática del
      // dinero del recibo (`cuota`/`totales`).
      return _pdfBloqueMoraRows(moraRows, k);
    case 'pie':
      if (settings.pieRecibo.isEmpty) return const [];
      return [
        pw.Text(settings.pieRecibo,
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    case 'whatsapp':
      if (settings.empresaWhatsapp.isEmpty) return const [];
      return [
        pw.Text('WhatsApp: ${settings.empresaWhatsapp}',
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    default:
      return const [];
  }
}

/// PDF para cobro múltiple (varios pagos agrupados).
///
/// [logoBytes] opcional: si se provee, se renderiza el logo de la empresa
/// centrado horizontalmente arriba del nombre de la empresa.
///
/// [moraRows] = detalle de mora del contrato YA filtrado por el call-site
/// (excluidas TODAS las cuotas del grupo). Vacío → el bloque `mora` no se
/// muestra. Ver `buildReciboPdf` para el razonamiento del parámetro.
Future<pw.Document> buildMultiReciboPdf({
  required List<Map<String, dynamic>> rows,
  required AppSettings settings,
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
}) async {
  final doc = pw.Document();
  final theme = await pdfTheme();
  final ancho = _anchoPuntos(settings.formatoReciboMm);

  // Se ITERA el MISMO layout configurable que el recibo single. Los ids mapean
  // a su contenido MULTI (lista de N cuotas, totales sumados). Entre bloques
  // SOLO espaciado (sin líneas) — estilo limpio. El bloque `totales` (dinero)
  // mantiene su matemática IDÉNTICA; solo cambia su posición.
  final children = <pw.Widget>[];
  String? zonaPrev;
  for (final b in settings.reciboLayout) {
    if (!b.visible) continue;
    final contenido = _pdfBloqueMulti(b.id, _pdfScale(b.size), rows, settings,
        logoBytes: logoBytes, moraRows: moraRows);
    if (contenido.isEmpty) continue;
    final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
    if (children.isNotEmpty) {
      if (zonaPrev == 'header' && zona == ReciboZona.header) {
        children.add(pw.SizedBox(height: 2));
      } else {
        children.add(pw.SizedBox(height: 6));
      }
    }
    children.addAll(contenido);
    zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
  }

  doc.addPage(
    pw.Page(
      theme: theme,
      pageFormat: PdfPageFormat(ancho, double.infinity,
          marginLeft: 8, marginRight: 8, marginTop: 12, marginBottom: 12),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: children,
      ),
    ),
  );
  return doc;
}

/// Construye las líneas de UN bloque del recibo MULTI en PDF. Devuelve [] si el
/// bloque no aplica. El bloque `servicio` va vacío en multi (la lista de cuotas
/// del bloque `cuota` ya lo cubre).
List<pw.Widget> _pdfBloqueMulti(
  String id,
  double k,
  List<Map<String, dynamic>> rows,
  AppSettings settings, {
  Uint8List? logoBytes,
  List<Map<String, dynamic>> moraRows = const [],
}) {
  final first = rows.first;
  switch (id) {
    case 'logo':
      if (logoBytes == null) return const [];
      return [
        pw.Image(pw.MemoryImage(logoBytes),
            height: 50 * k, fit: pw.BoxFit.contain),
      ];
    case 'empresa':
      final out = <pw.Widget>[];
      if (settings.empresaNombre.isNotEmpty) {
        out.add(pw.Text(
          settings.empresaNombre.toUpperCase(),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11 * k),
          textAlign: pw.TextAlign.center,
        ));
      }
      if (settings.empresaDireccion.isNotEmpty) {
        out.add(pw.Text(settings.empresaDireccion,
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center));
      }
      if (settings.empresaTelefono.isNotEmpty) {
        out.add(pw.Text('Tel: ${settings.empresaTelefono}',
            style: pw.TextStyle(fontSize: 8 * k)));
      }
      if (settings.empresaRuc.isNotEmpty) {
        out.add(pw.Text('RUC: ${settings.empresaRuc}',
            style: pw.TextStyle(fontSize: 8 * k)));
      }
      return out;
    case 'titulo':
      if (settings.reciboTitulo.isEmpty) return const [];
      return [
        pw.Text(
          settings.reciboTitulo.toUpperCase(),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k),
          textAlign: pw.TextAlign.center,
        ),
      ];
    case 'meta':
      final emision = DateTime.parse(first['fecha_pago'] as String);
      return [
        pw.Text('COBRO MÚLTIPLE (${rows.length} cuotas)',
            style:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
        pw.SizedBox(height: 4),
        _pdfRow('Recibos',
            '${rows.first['numero_completo']} - ${rows.last['numero_completo']}',
            k),
        _pdfRow('Fecha', Fmt.fechaCorta(emision), k),
        _pdfRow('Hora', Fmt.hora(emision), k),
        _pdfRow('Cobrador', first['cobrador_nombre'] as String, k),
      ];
    case 'cliente':
      return [
        _pdfRow('Cliente', first['cliente_nombre'] as String, k),
        if (settings.reciboMostrarCedula && first['cliente_cedula'] != null)
          _pdfRow('Cédula', first['cliente_cedula'] as String, k),
      ];
    case 'servicio':
      // En multi la lista de cuotas (bloque `cuota`) ya cubre el servicio.
      return const [];
    case 'cuota':
      // La LISTA de N cuotas: período → monto aplicado de cada una.
      return [
        for (final r in rows)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                  child: pw.Text(
                    Fmt.mesServicioLabel(
                      DateTime.parse(r['periodo'] as String),
                      r['plan_nombre'] == null
                          ? null
                          : (r['dia_pago'] as num?)?.toInt(),
                    ),
                    style: pw.TextStyle(fontSize: 8 * k),
                  ),
                ),
                pw.Text(Fmt.cordobas(r['monto_cordobas'] as num),
                    style: pw.TextStyle(fontSize: 8 * k)),
              ],
            ),
          ),
      ];
    case 'metodo':
      final totalOriginal = _multiTotalOriginal(rows);
      final esUsd = (first['moneda'] as String?) == 'USD';
      return [
        _pdfRow(
            'Método',
            MetodoPago.fromString(first['metodo'] as String)
                .label
                .toUpperCase(),
            k),
        if (first['referencia'] != null)
          _pdfRow('Ref.', first['referencia'] as String, k),
        if (esUsd)
          _pdfRow(
            'Recibido',
            'US\$${totalOriginal.toStringAsFixed(2)} '
                '(tasa ${(first['tasa_conversion'] as num).toStringAsFixed(2)})',
            k,
          ),
      ];
    case 'letras':
      final totalCobrado = _multiTotalCobrado(rows);
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Text(
            // Monto en letras = COBRADO (lo que entró a caja).
            montoALetras(totalCobrado,
                moneda: (first['moneda'] as String?) ?? 'NIO'),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 7 * k, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ];
    case 'totales':
      // EL BLOQUE DE DINERO (multi). Matemática y contenido IDÉNTICOS al
      // original: TOTAL COBRADO + VUELTO/PAGADO sumados (USD = Σ monto_original).
      final totalCobrado = _multiTotalCobrado(rows);
      final totalVuelto = _multiTotalVuelto(rows);
      final totalOriginal = _multiTotalOriginal(rows);
      final totalEntregado = totalCobrado + totalVuelto;
      // Todo el grupo comparte moneda/tasa (registrarCobroMultiple usa una sola).
      final esUsd = (first['moneda'] as String?) == 'USD';
      return [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('TOTAL COBRADO',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k)),
            pw.Text(Fmt.cordobas(totalCobrado),
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 11 * k)),
          ],
        ),
        if (totalVuelto > 0.01) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
                pw.Text(Fmt.cordobas(totalVuelto),
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
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
                        fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
                pw.Text(
                    esUsd
                        ? 'US\$${totalOriginal.toStringAsFixed(2)} = ${Fmt.cordobas(totalEntregado)}'
                        : Fmt.cordobas(totalEntregado),
                    style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
              ],
            ),
          ),
        ],
      ];
    case 'mora':
      // Detalle de mora del contrato (ya filtrado por el call-site, excluidas
      // las cuotas del grupo). Resumen informativo — no toca el dinero.
      return _pdfBloqueMoraRows(moraRows, k);
    case 'pie':
      if (settings.pieRecibo.isEmpty) return const [];
      return [
        pw.Text(settings.pieRecibo,
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    case 'whatsapp':
      if (settings.empresaWhatsapp.isEmpty) return const [];
      return [
        pw.Text('WhatsApp: ${settings.empresaWhatsapp}',
            style: pw.TextStyle(fontSize: 8 * k),
            textAlign: pw.TextAlign.center),
      ];
    default:
      return const [];
  }
}

/// Bloque `mora` en PDF (compartido single + multi): título "EN MORA", una
/// línea por mes (`Fmt.mes` ↔ `Fmt.cordobas(saldo)`), y "TOTAL MORA" con la
/// suma. `moraRows` ya viene filtrado por el call-site; vacío → [].
List<pw.Widget> _pdfBloqueMoraRows(
    List<Map<String, dynamic>> moraRows, double k) {
  if (moraRows.isEmpty) return const [];
  final totalMora = moraRows.fold<double>(
      0, (s, m) => s + (m['saldo'] as num).toDouble());
  return [
    pw.Text('EN MORA',
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k),
        textAlign: pw.TextAlign.center),
    pw.SizedBox(height: 2),
    for (final m in moraRows)
      _pdfRow(
        Fmt.mes(DateTime.parse(m['periodo'] as String)),
        Fmt.cordobas(m['saldo'] as num),
        k,
      ),
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('TOTAL MORA',
            style:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
        pw.Text(Fmt.cordobas(totalMora),
            style:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
      ],
    ),
  ];
}

// Totales del grupo (multi). Mismas sumas que antes (sin cambios de matemática).
double _multiTotalCobrado(List<Map<String, dynamic>> rows) {
  var t = 0.0;
  for (final r in rows) {
    t += (r['monto_cordobas'] as num).toDouble();
  }
  return t;
}

double _multiTotalVuelto(List<Map<String, dynamic>> rows) {
  var t = 0.0;
  for (final r in rows) {
    t += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
  }
  return t;
}

// Σ monto_original = lo entregado en moneda original.
double _multiTotalOriginal(List<Map<String, dynamic>> rows) {
  var t = 0.0;
  for (final r in rows) {
    t += (r['monto_original'] as num? ?? 0).toDouble();
  }
  return t;
}

// ---------------------------------------------------------------------------
// Helpers internos
// ---------------------------------------------------------------------------

pw.Widget _pdfRow(String label, String value, [double k = 1]) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 60,
          child: pw.Text('$label:', style: pw.TextStyle(fontSize: 8 * k)),
        ),
        pw.Expanded(
          child: pw.Text(value,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(fontSize: 8 * k)),
        ),
      ],
    ),
  );
}

List<pw.Widget> _vueltoIfNeeded(Map<String, dynamic> row, [double k = 1]) {
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
                  fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
          pw.Text(Fmt.cordobas(vuelto),
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 9 * k)),
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
                  fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
          pw.Text(pagadoLabel,
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: 10 * k)),
        ],
      ),
    ),
  ];
}
