import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/models/pago.dart';
import '../../data/models/recibo_layout.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../data/utils/monto_a_letras.dart';

// ---------------------------------------------------------------------------
// ReciboTicket — UN solo widget Flutter para el recibo, que se usa TANTO para
// la preview en pantalla COMO para imprimir en la térmica (capturándolo a
// imagen con `screenshot` y mandándolo como raster ESC/POS).
//
// Por qué un widget único:
//   - Lo renderiza Skia (el mismo motor que dibuja la pantalla) → las tildes
//     salen SIEMPRE bien en CUALQUIER impresora, sin depender del codepage del
//     modelo ni de fuentes embebidas (el problema del PDF + PDFium).
//   - La preview en pantalla = exactamente lo que se imprime (WYSIWYG).
//   - 100% offline: la captura no toca la red.
//
// La matemática del dinero (cobrado / vuelto / pagado / totales / mora) es
// IDÉNTICA a `recibo_pdf.dart`. Solo cambia el renderer (Flutter en vez de pw).
//
// El widget NO usa `ref`: recibe `logoBytes` (no URL) y `moraRows` (ya
// calculados/filtrados por el call-site), igual que los builders del PDF. Eso
// lo hace puro y capturable fuera del árbol (`captureFromWidget`).
// ---------------------------------------------------------------------------

/// Ancho del papel térmico en DOTS (px lógicos) según mm. 58mm→384, 80mm→576
/// (anchos útiles estándar ESC/POS). El ticket se construye a este ancho para
/// que la captura salga a la resolución exacta del papel (máxima nitidez sin
/// reescalado). Valores legacy (57) caen al angosto.
int reciboAnchoDots(int formatoMm) => formatoMm >= 80 ? 576 : 384;

class ReciboTicket extends StatelessWidget {
  const ReciboTicket({
    super.key,
    this.row,
    this.rows,
    required this.settings,
    this.logoBytes,
    this.moraRows = const [],
  }) : assert(row != null || rows != null,
            'ReciboTicket requiere row (single) o rows (multi)');

  /// Recibo individual (cuota única). Mutuamente excluyente con [rows].
  final Map<String, dynamic>? row;

  /// Cobro múltiple (varias cuotas agrupadas). Si está presente y tiene >1
  /// fila, el ticket se renderiza en modo multi.
  final List<Map<String, dynamic>>? rows;

  final AppSettings settings;

  /// Bytes del logo (PNG/JPG). Null → el bloque `logo` no muestra nada. Se
  /// pasan bytes (no URL) para que el render sea offline y capturable.
  final Uint8List? logoBytes;

  /// Detalle de mora del contrato YA filtrado por el call-site (excluida(s) la(s)
  /// cuota(s) cobrada(s)). Vacío → el bloque `mora` no se muestra. No toca la
  /// matemática del dinero del recibo.
  final List<Map<String, dynamic>> moraRows;

  /// True si hay que renderizar el modo multi-cuota.
  bool get _esMulti => rows != null && rows!.length > 1;

  @override
  Widget build(BuildContext context) {
    final anchoDots = reciboAnchoDots(settings.formatoReciboMm);
    // Escala base de la tipografía según el ancho del papel: 80mm (576) es la
    // referencia; 58mm (384) reduce proporcional para no desbordar el papel
    // angosto. Las fuentes de cada bloque se multiplican por esto + el `k` del
    // tamaño configurable.
    final baseFont = anchoDots / 576.0;

    final children = <Widget>[];
    String? zonaPrev;
    for (final b in settings.reciboLayout) {
      if (!b.visible) continue;
      final contenido = _buildBloque(b.id, _scaleDe(b.size) * baseFont);
      if (contenido.isEmpty) continue;
      final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
      if (children.isNotEmpty) {
        // Espaciado MODERADO: gap chico entre dos bloques de header (van más
        // juntos), gap mayor en el resto. Sin líneas divisorias (estilo limpio,
        // las secciones se distinguen por aire + negritas).
        if (zonaPrev == 'header' && zona == ReciboZona.header) {
          children.add(SizedBox(height: 4 * baseFont));
        } else {
          children.add(SizedBox(height: 10 * baseFont));
        }
      }
      children.addAll(contenido);
      zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
    }

    // Texto NEGRO sobre fondo BLANCO (térmico: monocromo). Sin azul.
    return Container(
      width: anchoDots.toDouble(),
      color: Colors.white,
      padding: EdgeInsets.symmetric(
          horizontal: 16 * baseFont, vertical: 16 * baseFont),
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13 * baseFont,
          height: 1.3,
          color: Colors.black,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }

  /// Multiplicador de fontSize según el tamaño del bloque (chico/normal/grande).
  /// Mismos factores que el PDF → consistencia entre renderers.
  double _scaleDe(ReciboTextoSize s) => switch (s) {
        ReciboTextoSize.chico => 0.85,
        ReciboTextoSize.grande => 1.3,
        ReciboTextoSize.normal => 1.0,
      };

  // Datos de referencia: en multi tomamos la primera fila para los campos
  // compartidos (cliente, método, fecha…). En single, `row`.
  Map<String, dynamic> get _ref => _esMulti ? rows!.first : (row ?? rows!.first);

  /// Construye las líneas de UN bloque. Devuelve [] si el bloque no tiene nada
  /// que mostrar — el loop del build salta los vacíos y su separador.
  List<Widget> _buildBloque(String id, double k) {
    final r = _ref;
    switch (id) {
      case 'logo':
        if (logoBytes == null) return const [];
        return [
          Image.memory(
            logoBytes!,
            height: 60 * k,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ];
      case 'empresa':
        final out = <Widget>[];
        if (settings.empresaNombre.isNotEmpty) {
          out.add(Text(
            settings.empresaNombre.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * k),
            textAlign: TextAlign.center,
          ));
        }
        if (settings.empresaDireccion.isNotEmpty) {
          out.add(Text(settings.empresaDireccion,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)));
        }
        if (settings.empresaTelefono.isNotEmpty) {
          out.add(Text('Tel: ${settings.empresaTelefono}',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)));
        }
        if (settings.empresaRuc.isNotEmpty) {
          out.add(Text('RUC: ${settings.empresaRuc}',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)));
        }
        return out;
      case 'titulo':
        if (settings.reciboTitulo.isEmpty) return const [];
        return [
          Text(
            settings.reciboTitulo.toUpperCase(),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k),
            textAlign: TextAlign.center,
          ),
        ];
      case 'meta':
        final emision = DateTime.parse(r['fecha_pago'] as String);
        if (_esMulti) {
          return [
            Text('COBRO MÚLTIPLE (${rows!.length} cuotas)',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * k)),
            SizedBox(height: 4 * k),
            _ticketRow('Recibos',
                '${rows!.first['numero_completo']} - ${rows!.last['numero_completo']}',
                k),
            _ticketRow('Fecha', Fmt.fechaCorta(emision), k),
            _ticketRow('Hora', Fmt.hora(emision), k),
            _ticketRow('Cobrador', r['cobrador_nombre'] as String, k),
          ];
        }
        return [
          _ticketRow('Recibo Nº', r['numero_completo'] as String, k),
          _ticketRow('Fecha', Fmt.fechaCorta(emision), k),
          _ticketRow('Hora', Fmt.hora(emision), k),
          _ticketRow('Cobrador', r['cobrador_nombre'] as String, k),
        ];
      case 'cliente':
        return [
          _ticketRow('Cliente', r['cliente_nombre'] as String, k),
          if (settings.reciboMostrarCedula && r['cliente_cedula'] != null)
            _ticketRow('Cédula', r['cliente_cedula'] as String, k),
        ];
      case 'servicio':
        // En multi la lista de cuotas (bloque `cuota`) ya cubre el servicio.
        if (_esMulti) return const [];
        final periodoCuota = DateTime.parse(r['periodo'] as String);
        final diaPago = (r['dia_pago'] as num?)?.toInt();
        final esManual = r['plan_nombre'] == null;
        // Regla del 15 sobre día de pago del cliente, no fecha de emisión.
        // Cuotas manuales (sin contrato): mes del periodo directo.
        final periodoLabel = diaPago != null
            ? Fmt.periodoRecibo(diaPago, periodoCuota)
            : Fmt.mes(periodoCuota);
        return [
          _ticketRow(
              'Servicio',
              esManual
                  ? (r['cuota_descripcion'] as String? ?? 'Cuota manual')
                  : r['plan_nombre'] as String,
              k),
          _ticketRow('Período',
              periodoLabel[0].toUpperCase() + periodoLabel.substring(1), k),
        ];
      case 'cuota':
        if (_esMulti) {
          // La LISTA de N cuotas: período → monto aplicado de cada una.
          return [
            for (final cu in rows!)
              Padding(
                padding: EdgeInsets.only(bottom: 2 * k),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        Fmt.mesServicioLabel(
                          DateTime.parse(cu['periodo'] as String),
                          cu['plan_nombre'] == null
                              ? null
                              : (cu['dia_pago'] as num?)?.toInt(),
                        ),
                        softWrap: true,
                        style: TextStyle(fontSize: 12 * k),
                      ),
                    ),
                    SizedBox(width: 8 * k),
                    Text(Fmt.cordobas(cu['monto_cordobas'] as num),
                        style: TextStyle(fontSize: 12 * k)),
                  ],
                ),
              ),
          ];
        }
        // Saldo de la cuota tras este pago (sub-toggle `mostrar_adeudado`).
        final saldoCuota = ((r['cuota_monto'] as num).toDouble() +
                (r['cargos_neto'] as num? ?? 0).toDouble()) -
            (r['monto_pagado_cuota'] as num? ?? r['monto_cordobas'] as num)
                .toDouble();
        return [
          _ticketRow('Cuota base', Fmt.cordobas(r['cuota_monto'] as num), k),
          if (settings.reciboMostrarAdeudado && saldoCuota > 0.01)
            _ticketRow('Saldo cuota', Fmt.cordobas(saldoCuota), k),
        ];
      case 'metodo':
        final esUsd = (r['moneda'] as String?) == 'USD';
        final recibidoOriginal =
            _esMulti ? _totalOriginal() : (r['monto_original'] as num).toDouble();
        return [
          _ticketRow(
              'Método',
              MetodoPago.fromString(r['metodo'] as String).label.toUpperCase(),
              k),
          if (r['referencia'] != null)
            _ticketRow('Ref.', r['referencia'] as String, k),
          if (esUsd)
            _ticketRow(
              'Recibido',
              'US\$${recibidoOriginal.toStringAsFixed(2)} '
                  '(tasa ${(r['tasa_conversion'] as num).toStringAsFixed(2)})',
              k,
            ),
        ];
      case 'letras':
        // Monto en letras = COBRADO (lo que entró a caja).
        final cobrado =
            _esMulti ? _totalCobrado() : (r['monto_cordobas'] as num).toDouble();
        return [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 4 * k),
            child: Text(
              montoALetras(cobrado, moneda: (r['moneda'] as String?) ?? 'NIO'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11 * k, fontWeight: FontWeight.w600),
            ),
          ),
        ];
      case 'totales':
        return _buildTotales(k);
      case 'mora':
        return _buildMora(k);
      case 'pie':
        if (settings.pieRecibo.isEmpty) return const [];
        return [
          Text(settings.pieRecibo,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      case 'whatsapp':
        if (settings.empresaWhatsapp.isEmpty) return const [];
        return [
          Text('WhatsApp: ${settings.empresaWhatsapp}',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13 * k)),
        ];
      default:
        return const [];
    }
  }

  /// EL BLOQUE DE DINERO. Matemática y contenido IDÉNTICOS a `recibo_pdf.dart`:
  /// COBRADO (o TOTAL COBRADO en multi) siempre, + VUELTO/PAGADO si hubo vuelto
  /// (con manejo USD). Separación clara etiqueta↔valor con `spaceBetween` +
  /// `Expanded` → nunca se pegan ("COBRADO800,00").
  List<Widget> _buildTotales(double k) {
    if (_esMulti) {
      final totalCobrado = _totalCobrado();
      final totalVuelto = _totalVuelto();
      final totalOriginal = _totalOriginal();
      final totalEntregado = totalCobrado + totalVuelto;
      // Todo el grupo comparte moneda/tasa (registrarCobroMultiple usa una sola).
      final esUsd = (rows!.first['moneda'] as String?) == 'USD';
      return [
        _totalLine('TOTAL COBRADO', Fmt.cordobas(totalCobrado), 15 * k,
            bold: true),
        if (totalVuelto > 0.01) ...[
          SizedBox(height: 4 * k),
          _totalLine(esUsd ? 'VUELTO (en C\$)' : 'VUELTO',
              Fmt.cordobas(totalVuelto), 13 * k,
              bold: true),
          SizedBox(height: 2 * k),
          _totalLine(
            'PAGADO',
            esUsd
                ? 'US\$${totalOriginal.toStringAsFixed(2)} = ${Fmt.cordobas(totalEntregado)}'
                : Fmt.cordobas(totalEntregado),
            14 * k,
            bold: true,
          ),
        ],
      ];
    }
    final r = row!;
    final vuelto = (r['vuelto_cordobas'] as num? ?? 0).toDouble();
    final cobrado = (r['monto_cordobas'] as num).toDouble();
    final entregado = cobrado + vuelto;
    final esUsd = (r['moneda'] as String) == 'USD';
    return [
      // COBRADO = monto aplicado a la cuota (lo que entra a la caja).
      _totalLine('COBRADO', Fmt.cordobas(r['monto_cordobas'] as num), 15 * k,
          bold: true),
      // VUELTO + PAGADO: si hubo vuelto, mostrar ambos. Si no, COBRADO basta
      // (PAGADO == COBRADO en ese caso).
      if (vuelto > 0.01) ...[
        SizedBox(height: 4 * k),
        _totalLine(esUsd ? 'VUELTO (en C\$)' : 'VUELTO', Fmt.cordobas(vuelto),
            13 * k,
            bold: true),
        SizedBox(height: 4 * k),
        _totalLine(
          'PAGADO',
          esUsd
              ? 'US\$${(r['monto_original'] as num).toStringAsFixed(2)} = ${Fmt.cordobas(entregado)}'
              : Fmt.cordobas(entregado),
          14 * k,
          bold: true,
        ),
      ],
    ];
  }

  /// Bloque `mora` (single + multi): título "EN MORA", una línea por mes
  /// (`Fmt.mes` ↔ saldo), y "TOTAL MORA". `moraRows` ya viene filtrado por el
  /// call-site. Resumen informativo — no toca la matemática del dinero.
  List<Widget> _buildMora(double k) {
    if (moraRows.isEmpty) return const [];
    final totalMora =
        moraRows.fold<double>(0, (s, m) => s + (m['saldo'] as num).toDouble());
    return [
      Text('EN MORA',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13 * k)),
      SizedBox(height: 2 * k),
      for (final m in moraRows)
        _ticketRow(
          Fmt.mes(DateTime.parse(m['periodo'] as String)),
          Fmt.cordobas(m['saldo'] as num),
          k,
        ),
      _totalLine('TOTAL MORA', Fmt.cordobas(totalMora), 13 * k, bold: true),
    ];
  }

  // ----- Sumas del grupo (multi). Matemática idéntica a `recibo_pdf.dart`. ----
  double _totalCobrado() {
    var t = 0.0;
    for (final r in rows!) {
      t += (r['monto_cordobas'] as num).toDouble();
    }
    return t;
  }

  double _totalVuelto() {
    var t = 0.0;
    for (final r in rows!) {
      t += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
    }
    return t;
  }

  // Σ monto_original = lo entregado en moneda original.
  double _totalOriginal() {
    var t = 0.0;
    for (final r in rows!) {
      t += (r['monto_original'] as num? ?? 0).toDouble();
    }
    return t;
  }

  // ----- Helpers de layout (SIN overflow) -----------------------------------

  /// Fila "etiqueta: valor" — la etiqueta a la izquierda, el valor a la derecha
  /// alineado al final. El valor está `Expanded` + `softWrap` + `textAlign:end`
  /// → un valor largo BAJA de línea en vez de cortarse (el bug actual). El gap
  /// entre etiqueta y valor evita que se peguen.
  Widget _ticketRow(String label, String value, [double k = 1]) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 1 * k),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            flex: 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 96 * k),
              child: Text('$label:', style: TextStyle(fontSize: 13 * k)),
            ),
          ),
          SizedBox(width: 8 * k),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              softWrap: true,
              style: TextStyle(fontSize: 13 * k),
            ),
          ),
        ],
      ),
    );
  }

  /// Línea de total: etiqueta a la izquierda, valor a la derecha, SIEMPRE
  /// separados (`Expanded` en el valor con `textAlign: end`). Resuelve el bug
  /// "COBRADO800,00" pegado. Negrita para destacar el dinero (sin color, B/N).
  Widget _totalLine(String label, String value, double fontSize,
      {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.bold : FontWeight.w600,
      fontSize: fontSize,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: Text(label, style: style)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.end, softWrap: true, style: style),
        ),
      ],
    );
  }
}
