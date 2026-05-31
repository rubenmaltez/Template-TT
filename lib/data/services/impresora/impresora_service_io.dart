import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../../utils/formatters.dart';

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
    List<Map<String, dynamic>>? multiRecibos,
  }) async {
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
    String? empresaWhatsapp,
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[];

    // Reimpresión visible al INICIO (donde el cliente la ve primero).
    if (esReimpresion) {
      bytes.addAll(gen.text('*** REIMPRESIÓN ***',
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)));
      bytes.addAll(gen.feed(1));
    }

    // Encabezado: empresa.
    final hayEmpresa = (empresa['nombre'] ?? '').isNotEmpty ||
        (empresa['direccion'] ?? '').isNotEmpty ||
        (empresa['telefono'] ?? '').isNotEmpty ||
        (empresa['ruc'] ?? '').isNotEmpty;

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
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    if ((empresa['telefono'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text('Tel: ${empresa['telefono']}',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    if ((empresa['ruc'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text('RUC: ${empresa['ruc']}',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    // Título configurable del recibo (ej. "RECIBO", "COBRO").
    if (reciboTitulo != null && reciboTitulo.isNotEmpty) {
      bytes.addAll(gen.text(reciboTitulo.toUpperCase(),
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)));
    }
    if (hayEmpresa) bytes.addAll(gen.hr());

    // Info del recibo.
    final emision = DateTime.parse(recibo['fecha_pago'] as String);
    bytes.addAll(_doblColumna(gen, anchoMm, 'Recibo Nº',
        recibo['numero_completo'] as String));
    bytes.addAll(_doblColumna(gen, anchoMm, 'Fecha',
        DateFormat('dd/MM/yyyy').format(emision)));
    bytes.addAll(_doblColumna(gen, anchoMm, 'Hora',
        DateFormat('HH:mm').format(emision)));
    if (recibo['cobrador_nombre'] != null) {
      bytes.addAll(_doblColumna(gen, anchoMm, 'Cobrador',
          recibo['cobrador_nombre'] as String));
    }
    bytes.addAll(gen.hr());

    // Cliente.
    bytes.addAll(_doblColumna(gen, anchoMm, 'Cliente',
        recibo['cliente_nombre'] as String));
    if (recibo['cliente_cedula'] != null) {
      bytes.addAll(_doblColumna(gen, anchoMm, 'Cédula',
          recibo['cliente_cedula'] as String));
    }
    bytes.addAll(gen.hr());

    // Servicio y período. Cuotas manuales no tienen plan ni contrato.
    final planNombre = recibo['plan_nombre'] as String?;
    final cuotaDesc = recibo['cuota_descripcion'] as String?;
    bytes.addAll(_doblColumna(gen, anchoMm, 'Servicio',
        planNombre ?? cuotaDesc ?? 'Cuota manual'));
    final periodoCuota = DateTime.parse(recibo['periodo'] as String);
    final diaPago = (recibo['dia_pago'] as num?)?.toInt();
    final periodoLabel = diaPago != null
        ? Fmt.periodoRecibo(diaPago, periodoCuota)
        : Fmt.mes(periodoCuota);
    bytes.addAll(_doblColumna(gen, anchoMm, 'Período',
        periodoLabel[0].toUpperCase() + periodoLabel.substring(1)));

    final cuotaMonto = (recibo['cuota_monto'] as num).toDouble();
    // cobrado = monto aplicado a la cuota (lo que entra a la caja).
    // vuelto = lo que se le devolvió al cliente (0 si no hubo).
    // entregado = cobrado + vuelto (lo que físicamente puso el cliente).
    final cobrado = (recibo['monto_cordobas'] as num).toDouble();
    final vuelto = (recibo['vuelto_cordobas'] as num? ?? 0).toDouble();
    final entregado = cobrado + vuelto;
    bytes.addAll(_doblColumna(gen, anchoMm, 'Cuota base',
        Fmt.cordobas(cuotaMonto)));
    bytes.addAll(gen.hr());

    // Método de pago.
    bytes.addAll(_doblColumna(gen, anchoMm, 'Método',
        (recibo['metodo'] as String).toUpperCase()));
    if (recibo['referencia'] != null) {
      bytes.addAll(_doblColumna(gen, anchoMm, 'Ref.',
          recibo['referencia'] as String));
    }
    bytes.addAll(gen.feed(1));

    // COBRADO — destacado (es lo que entra a la caja del ISP).
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

    // VUELTO + PAGADO si hubo vuelto.
    // Regla de negocio: el vuelto SIEMPRE se da en córdobas, incluso si
    // el cliente pagó en USD. El label refleja eso para evitar confusión.
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

    // Si fue en USD, mostrar equivalencia DESPUÉS del PAGADO (córdobas es
    // la moneda principal; lo otro es informativo).
    if ((recibo['moneda'] as String) == 'USD') {
      final original = (recibo['monto_original'] as num).toStringAsFixed(2);
      final tasa = (recibo['tasa_conversion'] as num).toStringAsFixed(2);
      bytes.addAll(gen.text(
        'Equivalente a US\$$original  (tasa $tasa)',
        styles: const PosStyles(align: PosAlign.center, codeTable: _codeTable),
      ));
    }

    // Si fue parcial, marcar el saldo restante para evitar que el cliente
    // crea que la cuota está al día.
    final cargosNeto = (recibo['cargos_neto'] as num? ?? 0).toDouble();
    final totalReal = (cuotaMonto + cargosNeto).clamp(0.0, double.infinity);
    final montoPagadoAcum = (recibo['monto_pagado_cuota'] as num? ?? cobrado).toDouble();
    final saldo = totalReal - montoPagadoAcum;
    if (mostrarAdeudado && saldo > 0.01) {
      bytes.addAll(gen.feed(1));
      bytes.addAll(gen.row([
        PosColumn(
          text: 'Saldo cuota',
          width: 6,
          styles: const PosStyles(bold: true, codeTable: _codeTable),
        ),
        PosColumn(
          text: Fmt.cordobas(saldo),
          width: 6,
          styles: const PosStyles(
              bold: true, align: PosAlign.right, codeTable: _codeTable),
        ),
      ]));
    }

    // Pie libre.
    if (pieRecibo != null && pieRecibo.isNotEmpty) {
      bytes.addAll(gen.hr());
      bytes.addAll(gen.text(pieRecibo,
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }

    // WhatsApp de la empresa (configurable).
    if (empresaWhatsapp != null && empresaWhatsapp.isNotEmpty) {
      if (pieRecibo == null || pieRecibo.isEmpty) {
        bytes.addAll(gen.hr());
      } else {
        bytes.addAll(gen.feed(1));
      }
      bytes.addAll(gen.text('WhatsApp: $empresaWhatsapp',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }

    bytes.addAll(gen.feed(2));
    bytes.addAll(gen.cut());
    return bytes;
  }

  /// Genera el recibo de un cobro MÚLTIPLE (grupo de cuotas) — espeja el
  /// ticket en pantalla/PDF (#6a). Antes la impresión Bluetooth de un cobro
  /// multi sacaba solo la 1ª cuota. Itera las N filas: una línea por cuota +
  /// totales del grupo (COBRADO/VUELTO/PAGADO), con manejo de USD.
  Future<List<int>> _generarBytesMulti({
    required List<Map<String, dynamic>> rows,
    required Map<String, String> empresa,
    required int anchoMm,
    String? pieRecibo,
    bool esReimpresion = false,
    String? reciboTitulo,
    String? empresaWhatsapp,
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(_size(anchoMm), profile);
    final bytes = <int>[];
    final first = rows.first;

    if (esReimpresion) {
      bytes.addAll(gen.text('*** REIMPRESIÓN ***',
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)));
      bytes.addAll(gen.feed(1));
    }

    // Encabezado: empresa (idéntico al single).
    final hayEmpresa = (empresa['nombre'] ?? '').isNotEmpty ||
        (empresa['direccion'] ?? '').isNotEmpty ||
        (empresa['telefono'] ?? '').isNotEmpty ||
        (empresa['ruc'] ?? '').isNotEmpty;
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
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    if ((empresa['telefono'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text('Tel: ${empresa['telefono']}',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    if ((empresa['ruc'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text('RUC: ${empresa['ruc']}',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    if (reciboTitulo != null && reciboTitulo.isNotEmpty) {
      bytes.addAll(gen.text(reciboTitulo.toUpperCase(),
          styles: const PosStyles(
              align: PosAlign.center, bold: true, codeTable: _codeTable)));
    }
    if (hayEmpresa) bytes.addAll(gen.hr());

    bytes.addAll(gen.text('COBRO MÚLTIPLE (${rows.length} cuotas)',
        styles: const PosStyles(
            align: PosAlign.center, bold: true, codeTable: _codeTable)));
    bytes.addAll(gen.feed(1));

    // Meta del grupo.
    final emision = DateTime.parse(first['fecha_pago'] as String);
    bytes.addAll(_doblColumna(gen, anchoMm, 'Recibos',
        '${first['numero_completo']} - ${rows.last['numero_completo']}'));
    bytes.addAll(_doblColumna(
        gen, anchoMm, 'Fecha', DateFormat('dd/MM/yyyy').format(emision)));
    bytes.addAll(
        _doblColumna(gen, anchoMm, 'Hora', DateFormat('HH:mm').format(emision)));
    if (first['cobrador_nombre'] != null) {
      bytes.addAll(_doblColumna(
          gen, anchoMm, 'Cobrador', first['cobrador_nombre'] as String));
    }
    bytes.addAll(gen.hr());

    // Cliente.
    bytes.addAll(_doblColumna(
        gen, anchoMm, 'Cliente', first['cliente_nombre'] as String));
    if (first['cliente_cedula'] != null) {
      bytes.addAll(_doblColumna(
          gen, anchoMm, 'Cédula', first['cliente_cedula'] as String));
    }
    bytes.addAll(gen.hr());

    // Una línea por cuota (período → monto aplicado) + acumular totales.
    var totalCobrado = 0.0;
    var totalVuelto = 0.0;
    var totalOriginal = 0.0;
    for (final r in rows) {
      totalCobrado += (r['monto_cordobas'] as num).toDouble();
      totalVuelto += (r['vuelto_cordobas'] as num? ?? 0).toDouble();
      totalOriginal += (r['monto_original'] as num? ?? 0).toDouble();
      final periodo = DateTime.parse(r['periodo'] as String);
      final label = Fmt.mesServicioLabel(
        periodo,
        r['plan_nombre'] == null ? null : (r['dia_pago'] as num?)?.toInt(),
      );
      bytes.addAll(_doblColumna(gen, anchoMm, label,
          Fmt.cordobas((r['monto_cordobas'] as num).toDouble())));
    }
    final totalEntregado = totalCobrado + totalVuelto;
    final esUsd = (first['moneda'] as String?) == 'USD';
    bytes.addAll(gen.hr());

    // Método.
    bytes.addAll(_doblColumna(
        gen, anchoMm, 'Método', (first['metodo'] as String).toUpperCase()));
    if (first['referencia'] != null) {
      bytes.addAll(
          _doblColumna(gen, anchoMm, 'Ref.', first['referencia'] as String));
    }
    bytes.addAll(gen.feed(1));

    // TOTAL COBRADO — destacado.
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

    if (esUsd) {
      final tasa = (first['tasa_conversion'] as num).toStringAsFixed(2);
      bytes.addAll(gen.text(
        'Equivalente a US\$${totalOriginal.toStringAsFixed(2)}  (tasa $tasa)',
        styles: const PosStyles(align: PosAlign.center, codeTable: _codeTable),
      ));
    }

    // Pie libre.
    if (pieRecibo != null && pieRecibo.isNotEmpty) {
      bytes.addAll(gen.hr());
      bytes.addAll(gen.text(pieRecibo,
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }
    // WhatsApp.
    if (empresaWhatsapp != null && empresaWhatsapp.isNotEmpty) {
      if (pieRecibo == null || pieRecibo.isEmpty) {
        bytes.addAll(gen.hr());
      } else {
        bytes.addAll(gen.feed(1));
      }
      bytes.addAll(gen.text('WhatsApp: $empresaWhatsapp',
          styles: const PosStyles(
              align: PosAlign.center, codeTable: _codeTable)));
    }

    bytes.addAll(gen.feed(2));
    bytes.addAll(gen.cut());
    return bytes;
  }

  /// Renglón de dos columnas con proporción adaptada al ancho:
  ///   - 80mm (48 chars): 4/8 (label corto, valor largo a la derecha).
  ///   - 57mm (32 chars): 5/7 (más espacio al valor que suele ser nombre).
  List<int> _doblColumna(Generator gen, int anchoMm, String label, String valor) {
    final proporcion = anchoMm >= 80 ? (4, 8) : (5, 7);
    return gen.row([
      PosColumn(
        text: label,
        width: proporcion.$1,
        styles: const PosStyles(align: PosAlign.left, codeTable: _codeTable),
      ),
      PosColumn(
        text: valor,
        width: proporcion.$2,
        styles: const PosStyles(align: PosAlign.right, codeTable: _codeTable),
      ),
    ]);
  }
}
