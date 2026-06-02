import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../../models/recibo_layout.dart';
import '../../utils/formatters.dart';
import '../../utils/monto_a_letras.dart';

/// Información de una impresora Bluetooth pareada.
class ImpresoraBT {
  const ImpresoraBT({required this.nombre, required this.mac});
  final String nombre;
  final String mac;
}

/// Servicio para imprimir recibos en impresoras térmicas Bluetooth (ESC/POS).
/// Mobile only — web tiene un stub paralelo.
class ImpresoraService {
  /// Code page Latin-1 — cubre Ñ, acentos, € y caracteres usados en
  /// nombres en español. Soportado por casi todas las térmicas baratas.
  /// (CP437 default no tiene Ñ.)
  static const _codeTable = 'CP1252';

  bool get soportado => true;

  Future<bool> isBluetoothEnabled() async {
    try {
      return await PrintBluetoothThermal.bluetoothEnabled;
    } catch (_) {
      return false;
    }
  }

  /// Lista impresoras BT pareadas en el sistema operativo. NO escanea.
  Future<List<ImpresoraBT>> listarPareadas() async {
    final raw = await PrintBluetoothThermal.pairedBluetooths;
    return raw
        // ignore: deprecated_member_use — typo del paquete (macAdress).
        .map((b) => ImpresoraBT(nombre: b.name, mac: b.macAdress))
        .toList();
  }

  /// Imprime el recibo. Devuelve true al éxito.
  ///
  /// El recibo se compone iterando el LAYOUT configurable (`layout`): una lista
  /// ORDENADA de bloques (id + visible + tamaño). Los 3 renderers (pantalla /
  /// PDF / esta térmica) iteran la MISMA lista para salir consistentes.
  Future<bool> imprimir({
    required String macImpresora,
    required Map<String, dynamic> recibo,
    required Map<String, String> empresa,
    required int anchoMm,
    String? pieRecibo,
    bool esReimpresion = false,
    String? reciboTitulo,
    bool mostrarAdeudado = true,
    String? empresaWhatsapp,
    // Sub-toggle que SE MANTIENE: la cédula es opcional dentro del bloque
    // `cliente` (la visibilidad/orden del bloque la da el layout).
    bool mostrarCedula = true,
    // Layout configurable del recibo (orden + visibilidad + tamaño por bloque).
    // Supersede a mostrarEmpresa/ordenPie (que la daban antes).
    List<ReciboBloque> layout = const [],
    List<Map<String, dynamic>>? multiRecibos,
    // Detalle de mora del contrato YA filtrado por el call-site (excluida la
    // cuota cobrada en single; excluidas TODAS las del grupo en multi). Igual
    // que en el PDF: el service no tiene `ref` ni hace IO, así que la mora se
    // calcula afuera (`fetchMoraContrato`) y se pasa hecha. Vacío → el bloque
    // `mora` no se imprime.
    List<Map<String, dynamic>> moraRows = const [],
  }) async {
    // Si el caller no pasó layout (o llegó vacío), caer al default del catálogo.
    final layoutFinal = layout.isEmpty ? ReciboLayout.porDefecto : layout;
    // Cobro múltiple: imprimir las N cuotas del grupo (#6a). Si viene una sola
    // fila (o ninguna), cae al recibo single de siempre.
    final bytes = (multiRecibos != null && multiRecibos.length > 1)
        ? await _generarBytesMulti(
            rows: multiRecibos,
            empresa: empresa,
            anchoMm: anchoMm,
            pieRecibo: pieRecibo,
            esReimpresion: esReimpresion,
            reciboTitulo: reciboTitulo,
            empresaWhatsapp: empresaWhatsapp,
            mostrarCedula: mostrarCedula,
            layout: layoutFinal,
            moraRows: moraRows,
          )
        : await _generarBytes(
            recibo: recibo,
            empresa: empresa,
            anchoMm: anchoMm,
            pieRecibo: pieRecibo,
            esReimpresion: esReimpresion,
            reciboTitulo: reciboTitulo,
            mostrarAdeudado: mostrarAdeudado,
            empresaWhatsapp: empresaWhatsapp,
            mostrarCedula: mostrarCedula,
            layout: layoutFinal,
            moraRows: moraRows,
          );
    return _enviarBytes(macImpresora, bytes);
  }

  /// Imprime un recibo de prueba para validar conexión + papel.
  Future<bool> imprimirPrueba({
    required String macImpresora,
    required int anchoMm,
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[
      ...gen.text('--- PRUEBA DE IMPRESIÓN ---',
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)),
      ...gen.text(DateFormat('dd/MM/yyyy HH:mm:ss').format(DateTime.now()),
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)),
      ...gen.feed(1),
      ...gen.text('Si lees esto, la impresora está OK.',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)),
      ...gen.feed(3),
      ...gen.cut(),
    ];
    return _enviarBytes(macImpresora, bytes);
  }

  /// Conecta → escribe → desconecta. Maneja errores silenciosos.
  Future<bool> _enviarBytes(String mac, List<int> bytes) async {
    try {
      final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (!ok) return false;
      final result = await PrintBluetoothThermal.writeBytes(bytes);
      await PrintBluetoothThermal.disconnect;
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('Impresora: $e');
      try {
        await PrintBluetoothThermal.disconnect;
      } catch (_) {}
      return false;
    }
  }

  PaperSize _size(int mm) => mm >= 80 ? PaperSize.mm80 : PaperSize.mm58;

  // ──────────────────────────────────────────────────────────────────
  // Composición del recibo en bytes ESC/POS
  // ──────────────────────────────────────────────────────────────────

  Future<List<int>> _generarBytes({
    required Map<String, dynamic> recibo,
    required Map<String, String> empresa,
    required int anchoMm,
    String? pieRecibo,
    bool esReimpresion = false,
    String? reciboTitulo,
    bool mostrarAdeudado = true,
    bool mostrarCedula = true,
    String? empresaWhatsapp,
    required List<ReciboBloque> layout,
    List<Map<String, dynamic>> moraRows = const [],
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[];

    // Reimpresión visible al INICIO (donde el cliente la ve primero). NO es un
    // bloque del layout — es metadata de la impresión, va siempre arriba.
    if (esReimpresion) {
      bytes.addAll(gen.text('*** REIMPRESIÓN ***',
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)));
      bytes.addAll(gen.feed(1));
    }

    // Se ITERA el layout configurable: cada bloque produce sus bytes en
    // `_bloqueSingle` (vacío si no hay nada que mostrar). Entre dos bloques de
    // header NO se emite hr() (se apilan, como empresa+título antes); en el
    // resto sí. El bloque `totales` (dinero) conserva su contenido/matemática.
    String? zonaPrev;
    for (final b in layout) {
      if (!b.visible) continue;
      final size = _posSize(b.size);
      final contenido = _bloqueSingle(
        gen,
        anchoMm,
        b.id,
        size,
        recibo: recibo,
        empresa: empresa,
        reciboTitulo: reciboTitulo,
        pieRecibo: pieRecibo,
        empresaWhatsapp: empresaWhatsapp,
        mostrarAdeudado: mostrarAdeudado,
        mostrarCedula: mostrarCedula,
        moraRows: moraRows,
      );
      if (contenido.isEmpty) continue;
      final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
      // Separador SOLO entre dos bloques REALES ya emitidos (zonaPrev != null),
      // y nunca entre dos de header (se apilan, como empresa+título antes). El
      // header de reimpresión no cuenta como bloque (no setea zonaPrev), así
      // que el primer bloque visible no lleva hr arriba.
      if (zonaPrev != null &&
          !(zonaPrev == 'header' && zona == ReciboZona.header)) {
        bytes.addAll(gen.hr());
      }
      bytes.addAll(contenido);
      zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
    }

    bytes.addAll(gen.feed(2));
    bytes.addAll(gen.cut());
    return bytes;
  }

  /// Construye los bytes ESC/POS de UN bloque del recibo single. Devuelve []
  /// (vacío) si el bloque no tiene nada que mostrar. El tamaño `size` viene del
  /// layout (chico/normal→size1, grande→size2); los TOTALES mantienen su size2
  /// propio (COBRADO destacado) sin importar el size del bloque.
  List<int> _bloqueSingle(
    Generator gen,
    int anchoMm,
    String id,
    PosTextSize size, {
    required Map<String, dynamic> recibo,
    required Map<String, String> empresa,
    String? reciboTitulo,
    String? pieRecibo,
    String? empresaWhatsapp,
    bool mostrarAdeudado = true,
    bool mostrarCedula = true,
    List<Map<String, dynamic>> moraRows = const [],
  }) {
    final bytes = <int>[];
    switch (id) {
      case 'logo':
        // La térmica no imprime el logo (no hay imagen) → bloque vacío.
        return const [];
      case 'empresa':
        final hayEmpresa = (empresa['nombre'] ?? '').isNotEmpty ||
            (empresa['direccion'] ?? '').isNotEmpty ||
            (empresa['telefono'] ?? '').isNotEmpty ||
            (empresa['ruc'] ?? '').isNotEmpty;
        if (!hayEmpresa) return const [];
        // El nombre va destacado en size2 (como siempre), salvo que el bloque
        // pida grande igual (entonces ya es size2). El resto sigue `size`.
        if ((empresa['nombre'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text(
            empresa['nombre']!.toUpperCase(),
            styles: const PosStyles(
                align: PosAlign.center,
                bold: true,
                height: PosTextSize.size2,
                codeTable: _codeTable),
          ));
        }
        if ((empresa['direccion'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text(empresa['direccion']!,
              styles: PosStyles(
                  align: PosAlign.center,
                  height: size,
                  codeTable: _codeTable)));
        }
        if ((empresa['telefono'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text('Tel: ${empresa['telefono']}',
              styles: PosStyles(
                  align: PosAlign.center,
                  height: size,
                  codeTable: _codeTable)));
        }
        if ((empresa['ruc'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text('RUC: ${empresa['ruc']}',
              styles: PosStyles(
                  align: PosAlign.center,
                  height: size,
                  codeTable: _codeTable)));
        }
        return bytes;
      case 'titulo':
        if (reciboTitulo == null || reciboTitulo.isEmpty) return const [];
        bytes.addAll(gen.text(reciboTitulo.toUpperCase(),
            styles: PosStyles(
                align: PosAlign.center,
                bold: true,
                height: size,
                codeTable: _codeTable)));
        return bytes;
      case 'meta':
        final emision = DateTime.parse(recibo['fecha_pago'] as String);
        bytes.addAll(_doblColumna(gen, anchoMm, 'Recibo Nº',
            recibo['numero_completo'] as String, size));
        bytes.addAll(_doblColumna(gen, anchoMm, 'Fecha',
            DateFormat('dd/MM/yyyy').format(emision), size));
        bytes.addAll(_doblColumna(gen, anchoMm, 'Hora',
            DateFormat('HH:mm').format(emision), size));
        if (recibo['cobrador_nombre'] != null) {
          bytes.addAll(_doblColumna(gen, anchoMm, 'Cobrador',
              recibo['cobrador_nombre'] as String, size));
        }
        return bytes;
      case 'cliente':
        bytes.addAll(_doblColumna(gen, anchoMm, 'Cliente',
            recibo['cliente_nombre'] as String, size));
        // Cédula: solo si el sub-toggle está activo y existe el dato.
        if (mostrarCedula && recibo['cliente_cedula'] != null) {
          bytes.addAll(_doblColumna(gen, anchoMm, 'Cédula',
              recibo['cliente_cedula'] as String, size));
        }
        return bytes;
      case 'servicio':
        final planNombre = recibo['plan_nombre'] as String?;
        final cuotaDesc = recibo['cuota_descripcion'] as String?;
        bytes.addAll(_doblColumna(gen, anchoMm, 'Servicio',
            planNombre ?? cuotaDesc ?? 'Cuota manual', size));
        final periodoCuota = DateTime.parse(recibo['periodo'] as String);
        final diaPago = (recibo['dia_pago'] as num?)?.toInt();
        final periodoLabel = diaPago != null
            ? Fmt.periodoRecibo(diaPago, periodoCuota)
            : Fmt.mes(periodoCuota);
        bytes.addAll(_doblColumna(gen, anchoMm, 'Período',
            periodoLabel[0].toUpperCase() + periodoLabel.substring(1), size));
        return bytes;
      case 'cuota':
        final cuotaMonto = (recibo['cuota_monto'] as num).toDouble();
        bytes.addAll(_doblColumna(
            gen, anchoMm, 'Cuota base', Fmt.cordobas(cuotaMonto), size));
        // Saldo restante (sub-toggle `mostrar_adeudado`): así el cliente no
        // cree que la cuota quedó al día si fue parcial.
        final cargosNeto = (recibo['cargos_neto'] as num? ?? 0).toDouble();
        final totalReal = (cuotaMonto + cargosNeto).clamp(0.0, double.infinity);
        final cobrado = (recibo['monto_cordobas'] as num).toDouble();
        final montoPagadoAcum =
            (recibo['monto_pagado_cuota'] as num? ?? cobrado).toDouble();
        final saldo = totalReal - montoPagadoAcum;
        if (mostrarAdeudado && saldo > 0.01) {
          bytes.addAll(_doblColumna(
              gen, anchoMm, 'Saldo cuota', Fmt.cordobas(saldo), size));
        }
        return bytes;
      case 'metodo':
        bytes.addAll(_doblColumna(gen, anchoMm, 'Método',
            (recibo['metodo'] as String).toUpperCase(), size));
        if (recibo['referencia'] != null) {
          bytes.addAll(_doblColumna(
              gen, anchoMm, 'Ref.', recibo['referencia'] as String, size));
        }
        // Si pagó en USD: cuánto entregó en USD + tasa. Espeja el "Recibido"
        // de pantalla/PDF (antes esto vivía suelto después del PAGADO).
        if ((recibo['moneda'] as String) == 'USD') {
          final original = (recibo['monto_original'] as num).toStringAsFixed(2);
          final tasa = (recibo['tasa_conversion'] as num).toStringAsFixed(2);
          bytes.addAll(_doblColumna(
              gen, anchoMm, 'Recibido', 'US\$$original (tasa $tasa)', size));
        }
        return bytes;
      case 'letras':
        // La térmica no imprimía letras antes; el layout puede activarlo.
        // Texto centrado con el monto COBRADO en letras.
        bytes.addAll(gen.text(
          montoALetras(
            (recibo['monto_cordobas'] as num).toDouble(),
            moneda: (recibo['moneda'] as String?) ?? 'NIO',
          ),
          styles: PosStyles(
              align: PosAlign.center,
              bold: true,
              height: size,
              codeTable: _codeTable),
        ));
        return bytes;
      case 'totales':
        // EL BLOQUE DE DINERO. Contenido y matemática IDÉNTICOS al original:
        // COBRADO destacado (size2 fijo) + VUELTO/PAGADO si hubo vuelto, con
        // manejo USD. NO depende del size del bloque (es el dato crítico).
        final cobrado = (recibo['monto_cordobas'] as num).toDouble();
        final vuelto = (recibo['vuelto_cordobas'] as num? ?? 0).toDouble();
        final entregado = cobrado + vuelto;
        bytes.addAll(gen.feed(1));
        bytes.addAll(gen.row([
          PosColumn(
            text: 'COBRADO',
            width: 6,
            styles: const PosStyles(
                bold: true, height: PosTextSize.size2, codeTable: _codeTable),
          ),
          PosColumn(
            text: Fmt.cordobas(cobrado),
            width: 6,
            styles: const PosStyles(
                bold: true,
                align: PosAlign.right,
                height: PosTextSize.size2,
                codeTable: _codeTable),
          ),
        ]));
        // VUELTO + PAGADO si hubo vuelto. El vuelto SIEMPRE en córdobas (aun si
        // pagó USD) — el label lo aclara.
        if (vuelto > 0.01) {
          final esUsd = (recibo['moneda'] as String) == 'USD';
          bytes.addAll(gen.row([
            PosColumn(
              text: esUsd ? 'VUELTO (C\$)' : 'VUELTO',
              width: 6,
              styles: const PosStyles(bold: true, codeTable: _codeTable),
            ),
            PosColumn(
              text: Fmt.cordobas(vuelto),
              width: 6,
              styles: const PosStyles(
                  bold: true, align: PosAlign.right, codeTable: _codeTable),
            ),
          ]));
          final pagadoText = esUsd
              ? 'US\$${(recibo['monto_original'] as num).toStringAsFixed(2)}=${Fmt.cordobas(entregado)}'
              : Fmt.cordobas(entregado);
          bytes.addAll(gen.row([
            PosColumn(
              text: 'PAGADO',
              width: 6,
              styles: const PosStyles(bold: true, codeTable: _codeTable),
            ),
            PosColumn(
              text: pagadoText,
              width: 6,
              styles: const PosStyles(
                  bold: true, align: PosAlign.right, codeTable: _codeTable),
            ),
          ]));
        }
        return bytes;
      case 'pie':
        if (pieRecibo == null || pieRecibo.isEmpty) return const [];
        bytes.addAll(gen.text(pieRecibo,
            styles: PosStyles(
                align: PosAlign.center,
                height: size,
                codeTable: _codeTable)));
        return bytes;
      case 'whatsapp':
        if (empresaWhatsapp == null || empresaWhatsapp.isEmpty) {
          return const [];
        }
        bytes.addAll(gen.text('WhatsApp: $empresaWhatsapp',
            styles: PosStyles(
                align: PosAlign.center,
                height: size,
                codeTable: _codeTable)));
        return bytes;
      case 'mora':
        // Detalle de mora del contrato (ya filtrado por el call-site, excluida
        // la cuota cobrada). Resumen informativo de lo que el cliente aún debe
        // — NO toca la matemática del dinero (`cuota`/`totales`). Vacío (cuota
        // manual sin contrato, o sin meses en mora) → bloque vacío.
        return _bloqueMoraBytes(gen, anchoMm, moraRows, size);
      default:
        return const [];
    }
  }

  /// Genera el recibo de un cobro MÚLTIPLE (grupo de cuotas) — espeja el
  /// ticket en pantalla/PDF (#6a). Itera el MISMO layout configurable que el
  /// single; los ids mapean a su contenido MULTI (lista de N cuotas, totales
  /// sumados del grupo con manejo de USD). El bloque `totales` (dinero)
  /// conserva su contenido/matemática.
  Future<List<int>> _generarBytesMulti({
    required List<Map<String, dynamic>> rows,
    required Map<String, String> empresa,
    required int anchoMm,
    String? pieRecibo,
    bool esReimpresion = false,
    String? reciboTitulo,
    String? empresaWhatsapp,
    bool mostrarCedula = true,
    required List<ReciboBloque> layout,
    List<Map<String, dynamic>> moraRows = const [],
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[];

    // Reimpresión visible al INICIO. NO es un bloque del layout.
    if (esReimpresion) {
      bytes.addAll(gen.text('*** REIMPRESIÓN ***',
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)));
      bytes.addAll(gen.feed(1));
    }

    String? zonaPrev;
    for (final b in layout) {
      if (!b.visible) continue;
      final size = _posSize(b.size);
      final contenido = _bloqueMulti(
        gen,
        anchoMm,
        b.id,
        size,
        rows: rows,
        empresa: empresa,
        reciboTitulo: reciboTitulo,
        pieRecibo: pieRecibo,
        empresaWhatsapp: empresaWhatsapp,
        mostrarCedula: mostrarCedula,
        moraRows: moraRows,
      );
      if (contenido.isEmpty) continue;
      final zona = reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;
      if (zonaPrev != null &&
          !(zonaPrev == 'header' && zona == ReciboZona.header)) {
        bytes.addAll(gen.hr());
      }
      bytes.addAll(contenido);
      zonaPrev = zona == ReciboZona.header ? 'header' : 'otro';
    }

    bytes.addAll(gen.feed(2));
    bytes.addAll(gen.cut());
    return bytes;
  }

  /// Construye los bytes ESC/POS de UN bloque del recibo MULTI. Devuelve []
  /// (vacío) si el bloque no aplica. El bloque `servicio` va vacío en multi
  /// (la lista de cuotas del bloque `cuota` ya lo cubre).
  List<int> _bloqueMulti(
    Generator gen,
    int anchoMm,
    String id,
    PosTextSize size, {
    required List<Map<String, dynamic>> rows,
    required Map<String, String> empresa,
    String? reciboTitulo,
    String? pieRecibo,
    String? empresaWhatsapp,
    bool mostrarCedula = true,
    List<Map<String, dynamic>> moraRows = const [],
  }) {
    final bytes = <int>[];
    final first = rows.first;
    switch (id) {
      case 'logo':
        return const [];
      case 'empresa':
        final hayEmpresa = (empresa['nombre'] ?? '').isNotEmpty ||
            (empresa['direccion'] ?? '').isNotEmpty ||
            (empresa['telefono'] ?? '').isNotEmpty ||
            (empresa['ruc'] ?? '').isNotEmpty;
        if (!hayEmpresa) return const [];
        if ((empresa['nombre'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text(empresa['nombre']!.toUpperCase(),
              styles: const PosStyles(
                  align: PosAlign.center,
                  bold: true,
                  height: PosTextSize.size2,
                  codeTable: _codeTable)));
        }
        if ((empresa['direccion'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text(empresa['direccion']!,
              styles: PosStyles(
                  align: PosAlign.center,
                  height: size,
                  codeTable: _codeTable)));
        }
        if ((empresa['telefono'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text('Tel: ${empresa['telefono']}',
              styles: PosStyles(
                  align: PosAlign.center,
                  height: size,
                  codeTable: _codeTable)));
        }
        if ((empresa['ruc'] ?? '').isNotEmpty) {
          bytes.addAll(gen.text('RUC: ${empresa['ruc']}',
              styles: PosStyles(
                  align: PosAlign.center,
                  height: size,
                  codeTable: _codeTable)));
        }
        return bytes;
      case 'titulo':
        if (reciboTitulo == null || reciboTitulo.isEmpty) return const [];
        bytes.addAll(gen.text(reciboTitulo.toUpperCase(),
            styles: PosStyles(
                align: PosAlign.center,
                bold: true,
                height: size,
                codeTable: _codeTable)));
        return bytes;
      case 'meta':
        final emision = DateTime.parse(first['fecha_pago'] as String);
        bytes.addAll(gen.text('COBRO MÚLTIPLE (${rows.length} cuotas)',
            styles: const PosStyles(
                align: PosAlign.center, bold: true, codeTable: _codeTable)));
        bytes.addAll(gen.feed(1));
        bytes.addAll(_doblColumna(gen, anchoMm, 'Recibos',
            '${first['numero_completo']} - ${rows.last['numero_completo']}',
            size));
        bytes.addAll(_doblColumna(
            gen, anchoMm, 'Fecha', DateFormat('dd/MM/yyyy').format(emision), size));
        bytes.addAll(_doblColumna(
            gen, anchoMm, 'Hora', DateFormat('HH:mm').format(emision), size));
        if (first['cobrador_nombre'] != null) {
          bytes.addAll(_doblColumna(
              gen, anchoMm, 'Cobrador', first['cobrador_nombre'] as String, size));
        }
        return bytes;
      case 'cliente':
        bytes.addAll(_doblColumna(
            gen, anchoMm, 'Cliente', first['cliente_nombre'] as String, size));
        if (mostrarCedula && first['cliente_cedula'] != null) {
          bytes.addAll(_doblColumna(
              gen, anchoMm, 'Cédula', first['cliente_cedula'] as String, size));
        }
        return bytes;
      case 'servicio':
        // En multi la lista de cuotas (bloque `cuota`) ya cubre el servicio.
        return const [];
      case 'cuota':
        // La LISTA de N cuotas: período → monto aplicado de cada una.
        for (final r in rows) {
          final periodo = DateTime.parse(r['periodo'] as String);
          final label = Fmt.mesServicioLabel(
            periodo,
            r['plan_nombre'] == null ? null : (r['dia_pago'] as num?)?.toInt(),
          );
          bytes.addAll(_doblColumna(gen, anchoMm, label,
              Fmt.cordobas((r['monto_cordobas'] as num).toDouble()), size));
        }
        return bytes;
      case 'metodo':
        bytes.addAll(_doblColumna(
            gen, anchoMm, 'Método', (first['metodo'] as String).toUpperCase(),
            size));
        if (first['referencia'] != null) {
          bytes.addAll(_doblColumna(
              gen, anchoMm, 'Ref.', first['referencia'] as String, size));
        }
        // Si pagó en USD: Σ entregado en USD + tasa (espeja "Recibido" de
        // pantalla/PDF; antes esto iba suelto después del PAGADO).
        final esUsd = (first['moneda'] as String?) == 'USD';
        if (esUsd) {
          final tasa = (first['tasa_conversion'] as num).toStringAsFixed(2);
          bytes.addAll(_doblColumna(gen, anchoMm, 'Recibido',
              'US\$${_multiTotalOriginal(rows).toStringAsFixed(2)} (tasa $tasa)',
              size));
        }
        return bytes;
      case 'letras':
        // La térmica no imprimía letras antes; el layout puede activarlo.
        bytes.addAll(gen.text(
          montoALetras(_multiTotalCobrado(rows),
              moneda: (first['moneda'] as String?) ?? 'NIO'),
          styles: PosStyles(
              align: PosAlign.center,
              bold: true,
              height: size,
              codeTable: _codeTable),
        ));
        return bytes;
      case 'totales':
        // EL BLOQUE DE DINERO (multi). Contenido y matemática IDÉNTICOS al
        // original: TOTAL COBRADO (size2 fijo) + VUELTO/PAGADO sumados, con USD.
        final totalCobrado = _multiTotalCobrado(rows);
        final totalVuelto = _multiTotalVuelto(rows);
        final totalOriginal = _multiTotalOriginal(rows);
        final totalEntregado = totalCobrado + totalVuelto;
        final esUsd = (first['moneda'] as String?) == 'USD';
        bytes.addAll(gen.feed(1));
        bytes.addAll(gen.row([
          PosColumn(
              text: 'TOTAL COBRADO',
              width: 6,
              styles: const PosStyles(
                  bold: true, height: PosTextSize.size2, codeTable: _codeTable)),
          PosColumn(
              text: Fmt.cordobas(totalCobrado),
              width: 6,
              styles: const PosStyles(
                  bold: true,
                  align: PosAlign.right,
                  height: PosTextSize.size2,
                  codeTable: _codeTable)),
        ]));
        if (totalVuelto > 0.01) {
          bytes.addAll(gen.row([
            PosColumn(
                text: esUsd ? 'VUELTO (C\$)' : 'VUELTO',
                width: 6,
                styles: const PosStyles(bold: true, codeTable: _codeTable)),
            PosColumn(
                text: Fmt.cordobas(totalVuelto),
                width: 6,
                styles: const PosStyles(
                    bold: true, align: PosAlign.right, codeTable: _codeTable)),
          ]));
          final pagadoText = esUsd
              ? 'US\$${totalOriginal.toStringAsFixed(2)}=${Fmt.cordobas(totalEntregado)}'
              : Fmt.cordobas(totalEntregado);
          bytes.addAll(gen.row([
            PosColumn(
                text: 'PAGADO',
                width: 6,
                styles: const PosStyles(bold: true, codeTable: _codeTable)),
            PosColumn(
                text: pagadoText,
                width: 6,
                styles: const PosStyles(
                    bold: true, align: PosAlign.right, codeTable: _codeTable)),
          ]));
        }
        return bytes;
      case 'pie':
        if (pieRecibo == null || pieRecibo.isEmpty) return const [];
        bytes.addAll(gen.text(pieRecibo,
            styles: PosStyles(
                align: PosAlign.center,
                height: size,
                codeTable: _codeTable)));
        return bytes;
      case 'whatsapp':
        if (empresaWhatsapp == null || empresaWhatsapp.isEmpty) {
          return const [];
        }
        bytes.addAll(gen.text('WhatsApp: $empresaWhatsapp',
            styles: PosStyles(
                align: PosAlign.center,
                height: size,
                codeTable: _codeTable)));
        return bytes;
      case 'mora':
        // Detalle de mora del contrato (ya filtrado por el call-site, excluidas
        // TODAS las cuotas del grupo). Mismo resumen informativo que el single
        // — NO toca la matemática del dinero. Vacío → bloque vacío.
        return _bloqueMoraBytes(gen, anchoMm, moraRows, size);
      default:
        return const [];
    }
  }

  /// Bloque `mora` en bytes ESC/POS (compartido single + multi): título "EN
  /// MORA" centrado, una línea por mes (`Fmt.mes` ↔ `Fmt.cordobas(saldo)` en
  /// dos columnas), y "TOTAL MORA" con la suma. `moraRows` ya viene filtrado
  /// por el call-site; vacío → []. Mismos labels/orden que pantalla y PDF.
  List<int> _bloqueMoraBytes(Generator gen, int anchoMm,
      List<Map<String, dynamic>> moraRows, PosTextSize size) {
    if (moraRows.isEmpty) return const [];
    final bytes = <int>[];
    final totalMora = moraRows.fold<double>(
        0, (s, m) => s + (m['saldo'] as num).toDouble());
    bytes.addAll(gen.text('EN MORA',
        styles: PosStyles(
            align: PosAlign.center,
            bold: true,
            height: size,
            codeTable: _codeTable)));
    for (final m in moraRows) {
      bytes.addAll(_doblColumna(
        gen,
        anchoMm,
        Fmt.mes(DateTime.parse(m['periodo'] as String)),
        Fmt.cordobas(m['saldo'] as num),
        size,
      ));
    }
    bytes.addAll(gen.row([
      PosColumn(
        text: 'TOTAL MORA',
        width: 6,
        styles: const PosStyles(bold: true, codeTable: _codeTable),
      ),
      PosColumn(
        text: Fmt.cordobas(totalMora),
        width: 6,
        styles: const PosStyles(
            bold: true, align: PosAlign.right, codeTable: _codeTable),
      ),
    ]));
    return bytes;
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

  /// Mapea el tamaño del bloque (chico/normal/grande) al de la térmica ESC/POS.
  /// La térmica solo tiene tamaños discretos: chico/normal → size1 (normal);
  /// grande → size2 (doble alto). Solo escalamos el ALTO (no el ancho) para no
  /// desbordar las columnas de ancho fijo. Los totales fijan su size2 aparte.
  PosTextSize _posSize(ReciboTextoSize s) =>
      s == ReciboTextoSize.grande ? PosTextSize.size2 : PosTextSize.size1;

  /// Renglón de dos columnas con proporción adaptada al ancho:
  ///   - 80mm (48 chars): 4/8 (label corto, valor largo a la derecha).
  ///   - 57mm (32 chars): 5/7 (más espacio al valor que suele ser nombre).
  ///
  /// `size` escala el ALTO del texto (del tamaño del bloque). Default size1 =
  /// normal → idéntico al render previo (back-compat).
  List<int> _doblColumna(Generator gen, int anchoMm, String label, String valor,
      [PosTextSize size = PosTextSize.size1]) {
    final proporcion = anchoMm >= 80 ? (4, 8) : (5, 7);
    return gen.row([
      PosColumn(
        text: label,
        width: proporcion.$1,
        styles: PosStyles(
            align: PosAlign.left,
            height: size,
            codeTable: _codeTable),
      ),
      PosColumn(
        text: valor,
        width: proporcion.$2,
        styles: PosStyles(
            align: PosAlign.right,
            height: size,
            codeTable: _codeTable),
      ),
    ]);
  }
}
