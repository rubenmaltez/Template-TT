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
  }) async {
    return _enviarBytes(
      macImpresora,
      await _generarBytes(
        recibo: recibo,
        empresa: empresa,
        anchoMm: anchoMm,
        pieRecibo: pieRecibo,
        esReimpresion: esReimpresion,
      ),
    );
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

    // Servicio y período (regla del 15 — fuente única en Fmt.periodoRecibo).
    bytes.addAll(_doblColumna(gen, anchoMm, 'Servicio',
        recibo['plan_nombre'] as String));
    final periodoCuota = DateTime.parse(recibo['periodo'] as String);
    final diaPago = (recibo['dia_pago'] as num).toInt();
    final periodoLabel = Fmt.periodoRecibo(diaPago, periodoCuota);
    bytes.addAll(_doblColumna(gen, anchoMm, 'Período',
        periodoLabel[0].toUpperCase() + periodoLabel.substring(1)));

    final cuotaMonto = (recibo['cuota_monto'] as num).toDouble();
    final pagado = (recibo['monto_cordobas'] as num).toDouble();
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

    // Total pagado — destacado.
    bytes.addAll(gen.row([
      PosColumn(
        text: 'PAGADO',
        width: 6,
        styles: const PosStyles(
            bold: true, height: PosTextSize.size2, codeTable: _codeTable),
      ),
      PosColumn(
        text: Fmt.cordobas(pagado),
        width: 6,
        styles: const PosStyles(
            bold: true,
            align: PosAlign.right,
            height: PosTextSize.size2,
            codeTable: _codeTable),
      ),
    ]));

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
    final montoPagadoAcum = (recibo['monto_pagado_cuota'] as num? ?? pagado).toDouble();
    final saldo = totalReal - montoPagadoAcum;
    if (saldo > 0.01) {
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
