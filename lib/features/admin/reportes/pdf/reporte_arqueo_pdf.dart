import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pdf_theme.dart';
import 'pdf_utils.dart';

/// Reporte de arqueo / cierre por cobrador.
///
/// READ-ONLY: a partir de los pagos del rango, arma por cada cobrador un
/// bloque con el efectivo físico (separado por moneda US$/C$), el vuelto que
/// entregó, el electrónico (transferencia/depósito/tarjeta), y dos totales:
///   - Equivalente total en C$ valuando los dólares a la TASA ACTUAL.
///   - Ingreso registrado (recaudado contable, a la tasa de cada cobro).
///
/// [rows] viene de la query del screen con keys: cobrador_nombre,
/// total_cobros, efectivo_usd, efectivo_usd_qty, efectivo_nio,
/// efectivo_nio_qty, efectivo_vuelto, efectivo_ingreso, transferencia,
/// transferencia_qty, deposito, deposito_qty, tarjeta, tarjeta_qty,
/// ingreso_total.
Future<pw.Document> buildReporteArqueo({
  required String titulo,
  required String empresaNombre,
  required String periodo,
  required List<Map<String, dynamic>> rows,
  required double tasaActual,
}) async {
  final pdf = pw.Document();
  final theme = await pdfTheme();

  pdf.addPage(
    pw.MultiPage(
      theme: theme,
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.all(40),
      header: (context) => buildHeaderEstandar(
        empresaNombre: empresaNombre,
        titulo: titulo,
        periodo: '$periodo  ·  Tasa actual: ${fmtCordobas(tasaActual)}',
      ),
      footer: (context) => buildFooterEstandar(context),
      build: (context) {
        if (rows.isEmpty) {
          return [
            pw.Text('Sin cobros en el período seleccionado.',
                style: estiloCelda),
          ];
        }
        return [
          for (final r in rows) ...[
            _bloqueCobrador(_Arqueo.fromRow(r, tasaActual)),
            pw.SizedBox(height: 14),
          ],
          pw.SizedBox(height: 6),
          _bloqueTotalGeneral(_Arqueo.total(rows, tasaActual)),
        ];
      },
    ),
  );

  return pdf;
}

// ---------------------------------------------------------------------------
// Modelo de arqueo (matemática del cierre)
// ---------------------------------------------------------------------------

class _Arqueo {
  _Arqueo({
    required this.nombre,
    required this.totalCobros,
    required this.efectivoUsd,
    required this.efectivoUsdQty,
    required this.efectivoNio,
    required this.efectivoNioQty,
    required this.efectivoVuelto,
    required this.transferencia,
    required this.transferenciaQty,
    required this.deposito,
    required this.depositoQty,
    required this.tarjeta,
    required this.tarjetaQty,
    required this.ingresoTotal,
    required this.tasaActual,
  });

  final String nombre;
  final int totalCobros;
  final double efectivoUsd; // US$ físicos recibidos (monto_original)
  final int efectivoUsdQty;
  final double efectivoNio; // C$ físicos recibidos (monto_original)
  final int efectivoNioQty;
  final double efectivoVuelto; // C$ devueltos al cliente (todos los efectivo)
  final double transferencia;
  final int transferenciaQty;
  final double deposito;
  final int depositoQty;
  final double tarjeta;
  final int tarjetaQty;
  final double ingresoTotal; // recaudado contable (monto_cordobas)
  final double tasaActual;

  static double _d(Map<String, dynamic> r, String k) =>
      ((r[k] as num?) ?? 0).toDouble();
  static int _i(Map<String, dynamic> r, String k) =>
      ((r[k] as num?) ?? 0).toInt();

  factory _Arqueo.fromRow(Map<String, dynamic> r, double tasaActual) {
    return _Arqueo(
      nombre: (r['cobrador_nombre'] as String?) ?? '—',
      totalCobros: _i(r, 'total_cobros'),
      efectivoUsd: _d(r, 'efectivo_usd'),
      efectivoUsdQty: _i(r, 'efectivo_usd_qty'),
      efectivoNio: _d(r, 'efectivo_nio'),
      efectivoNioQty: _i(r, 'efectivo_nio_qty'),
      efectivoVuelto: _d(r, 'efectivo_vuelto'),
      transferencia: _d(r, 'transferencia'),
      transferenciaQty: _i(r, 'transferencia_qty'),
      deposito: _d(r, 'deposito'),
      depositoQty: _i(r, 'deposito_qty'),
      tarjeta: _d(r, 'tarjeta'),
      tarjetaQty: _i(r, 'tarjeta_qty'),
      ingresoTotal: _d(r, 'ingreso_total'),
      tasaActual: tasaActual,
    );
  }

  /// Suma todas las filas en un solo arqueo "TOTAL GENERAL".
  factory _Arqueo.total(List<Map<String, dynamic>> rows, double tasaActual) {
    double sumD(String k) =>
        rows.fold<double>(0, (s, r) => s + _d(r, k));
    int sumI(String k) => rows.fold<int>(0, (s, r) => s + _i(r, k));
    return _Arqueo(
      nombre: 'TOTAL GENERAL (todos los cobradores)',
      totalCobros: sumI('total_cobros'),
      efectivoUsd: sumD('efectivo_usd'),
      efectivoUsdQty: sumI('efectivo_usd_qty'),
      efectivoNio: sumD('efectivo_nio'),
      efectivoNioQty: sumI('efectivo_nio_qty'),
      efectivoVuelto: sumD('efectivo_vuelto'),
      transferencia: sumD('transferencia'),
      transferenciaQty: sumI('transferencia_qty'),
      deposito: sumD('deposito'),
      depositoQty: sumI('deposito_qty'),
      tarjeta: sumD('tarjeta'),
      tarjetaQty: sumI('tarjeta_qty'),
      ingresoTotal: sumD('ingreso_total'),
      tasaActual: tasaActual,
    );
  }

  /// Córdobas físicos netos: lo recibido en C$ menos TODO el vuelto entregado
  /// (el vuelto de pagos USD también sale de la caja en córdobas).
  double get efectivoNetoC => efectivoNio - efectivoVuelto;

  /// Dólares físicos valuados a la tasa de HOY.
  double get usdEnCordobasActual => efectivoUsd * tasaActual;

  /// Gran total en córdobas a tasa actual.
  double get equivalenteTotalC =>
      efectivoNetoC + usdEnCordobasActual + transferencia + deposito + tarjeta;

  bool get tieneUsd => efectivoUsd != 0;
}

// ---------------------------------------------------------------------------
// Bloques del PDF
// ---------------------------------------------------------------------------

pw.Widget _bloqueCobrador(_Arqueo a) => _bloque(a, destacado: false);

pw.Widget _bloqueTotalGeneral(_Arqueo a) => _bloque(a, destacado: true);

pw.Widget _bloque(_Arqueo a, {required bool destacado}) {
  // Líneas del sub-bloque ELECTRÓNICO: omitir depósito/tarjeta si monto y qty
  // son 0. Transferencia se muestra siempre que haya algo (consistencia).
  final electronico = <pw.Widget>[];
  if (a.transferencia != 0 || a.transferenciaQty != 0) {
    electronico.add(_renglonMetodo(
        'Transferencia', a.transferencia, a.transferenciaQty));
  }
  if (a.deposito != 0 || a.depositoQty != 0) {
    electronico
        .add(_renglonMetodo('Depósito', a.deposito, a.depositoQty));
  }
  if (a.tarjeta != 0 || a.tarjetaQty != 0) {
    electronico.add(_renglonMetodo('Tarjeta', a.tarjeta, a.tarjetaQty));
  }

  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: destacado ? PdfColors.blueGrey50 : PdfColors.white,
      borderRadius: pw.BorderRadius.circular(4),
      border: pw.Border.all(
        color: destacado ? PdfColors.blueGrey400 : PdfColors.grey300,
        width: destacado ? 1 : 0.5,
      ),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Encabezado: nombre + cantidad de cobros.
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(a.nombre.toUpperCase(), style: estiloTotal),
            ),
            pw.Text('${a.totalCobros} cobros', style: estiloCelda),
          ],
        ),
        pw.SizedBox(height: 6),

        // EFECTIVO (caja física).
        _subtitulo('EFECTIVO (caja física)'),
        if (a.tieneUsd)
          _renglon('Dólares recibidos',
              '${fmtDolares(a.efectivoUsd)}  (${a.efectivoUsdQty})'),
        _renglon('Córdobas recibidos',
            '${fmtCordobas(a.efectivoNio)}  (${a.efectivoNioQty})'),
        _renglon('(−) Vuelto entregado', fmtCordobas(a.efectivoVuelto)),
        _renglon(
          'Neto a entregar',
          a.tieneUsd
              ? '${fmtDolares(a.efectivoUsd)}  +  ${fmtCordobas(a.efectivoNetoC)}'
              : fmtCordobas(a.efectivoNetoC),
          bold: true,
        ),
        if (a.tieneUsd)
          _renglon('US\$ a tasa actual', fmtCordobas(a.usdEnCordobasActual)),

        // ELECTRÓNICO (al banco) — solo si hay algún método con movimiento.
        if (electronico.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          _subtitulo('ELECTRÓNICO (al banco)'),
          ...electronico,
        ],

        pw.SizedBox(height: 8),
        pw.Divider(thickness: 0.5, color: PdfColors.grey400),
        _renglon('Equivalente total (C\$, tasa actual)',
            fmtCordobas(a.equivalenteTotalC),
            bold: true),
        _renglon('Ingreso registrado (recaudado)',
            fmtCordobas(a.ingresoTotal)),
      ],
    ),
  );
}

pw.Widget _subtitulo(String texto) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 2, bottom: 2),
      child: pw.Text(
        texto,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blueGrey700,
        ),
      ),
    );

/// Renglón etiqueta → valor (valor alineado a la derecha).
pw.Widget _renglon(String etiqueta, String valor, {bool bold = false}) {
  final estilo = bold ? estiloTotal : estiloCelda;
  return pw.Padding(
    padding: const pw.EdgeInsets.only(left: 12, top: 1, bottom: 1),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(child: pw.Text(etiqueta, style: estilo)),
        pw.Text(valor, style: estilo),
      ],
    ),
  );
}

/// Renglón de método electrónico con monto + cantidad entre paréntesis.
pw.Widget _renglonMetodo(String etiqueta, double monto, int qty) =>
    _renglon(etiqueta, '${fmtCordobas(monto)}  ($qty)');
