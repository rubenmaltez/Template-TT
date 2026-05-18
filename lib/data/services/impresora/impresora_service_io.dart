import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

/// Información de una impresora Bluetooth pareada.
class ImpresoraBT {
  const ImpresoraBT({required this.nombre, required this.mac});
  final String nombre;
  final String mac;
}

/// Servicio para imprimir recibos en impresoras térmicas Bluetooth (ESC/POS).
/// Mobile only — web tiene un stub paralelo.
class ImpresoraService {
  bool get soportado => true;

  /// ¿El bluetooth del dispositivo está encendido?
  Future<bool> isBluetoothEnabled() async {
    try {
      return await PrintBluetoothThermal.bluetoothEnabled;
    } catch (_) {
      return false;
    }
  }

  /// Lista impresoras BT pareadas (las que el usuario ya pareó desde el
  /// sistema operativo). NO escanea — esa parte queda en el sistema.
  Future<List<ImpresoraBT>> listarPareadas() async {
    final raw = await PrintBluetoothThermal.pairedBluetooths;
    return raw
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
          styles: const PosStyles(align: PosAlign.center, bold: true)),
      ...gen.text(DateFormat('dd/MM/yyyy HH:mm:ss').format(DateTime.now()),
          styles: const PosStyles(align: PosAlign.center)),
      ...gen.feed(1),
      ...gen.text('Si lees esto, la impresora está OK.',
          styles: const PosStyles(align: PosAlign.center)),
      ...gen.feed(3),
      ...gen.cut(),
    ];
    return _enviarBytes(macImpresora, bytes);
  }

  /// Conecta + envía + desconecta. Cubre la mayoría de los casos de
  /// impresión esporádica (un cobro a la vez).
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

  /// 80mm → PaperSize.mm80 (48 chars); 57mm → PaperSize.mm58 (32 chars).
  PaperSize _size(int mm) =>
      mm >= 80 ? PaperSize.mm80 : PaperSize.mm58;

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

    // Encabezado: empresa.
    if ((empresa['nombre'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text(
        empresa['nombre']!.toUpperCase(),
        styles: const PosStyles(
            align: PosAlign.center, bold: true, height: PosTextSize.size2),
      ));
    }
    if ((empresa['direccion'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text(empresa['direccion']!,
          styles: const PosStyles(align: PosAlign.center)));
    }
    if ((empresa['telefono'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text('Tel: ${empresa['telefono']}',
          styles: const PosStyles(align: PosAlign.center)));
    }
    if ((empresa['ruc'] ?? '').isNotEmpty) {
      bytes.addAll(gen.text('RUC: ${empresa['ruc']}',
          styles: const PosStyles(align: PosAlign.center)));
    }
    bytes.addAll(gen.hr());

    // Info del recibo.
    final emision = DateTime.parse(recibo['fecha_pago'] as String);
    bytes.addAll(_doblColumna(gen, 'Recibo Nº', recibo['numero_completo'] as String));
    bytes.addAll(_doblColumna(gen, 'Fecha',
        DateFormat('dd/MM/yyyy').format(emision)));
    bytes.addAll(_doblColumna(gen, 'Hora',
        DateFormat('HH:mm').format(emision)));
    if (recibo['cobrador_nombre'] != null) {
      bytes.addAll(_doblColumna(gen, 'Cobrador',
          recibo['cobrador_nombre'] as String));
    }
    bytes.addAll(gen.hr());

    // Cliente.
    bytes.addAll(_doblColumna(gen, 'Cliente',
        recibo['cliente_nombre'] as String));
    if (recibo['cliente_cedula'] != null) {
      bytes.addAll(_doblColumna(gen, 'Cédula',
          recibo['cliente_cedula'] as String));
    }
    bytes.addAll(gen.hr());

    // Servicio y período.
    bytes.addAll(_doblColumna(gen, 'Servicio',
        recibo['plan_nombre'] as String));

    final periodoCuota = DateTime.parse(recibo['periodo'] as String);
    final diaPago = (recibo['dia_pago'] as num).toInt();
    final mesObjetivo = diaPago >= 15
        ? DateTime(periodoCuota.year, periodoCuota.month + 1, 1)
        : periodoCuota;
    final periodoLabel = DateFormat('MMMM y', 'es_NI').format(mesObjetivo);
    bytes.addAll(_doblColumna(gen, 'Período',
        periodoLabel[0].toUpperCase() + periodoLabel.substring(1)));

    bytes.addAll(_doblColumna(gen, 'Cuota base',
        _cordobas(recibo['cuota_monto'] as num)));
    bytes.addAll(gen.hr());

    // Método de pago.
    bytes.addAll(_doblColumna(gen, 'Método',
        (recibo['metodo'] as String).toUpperCase()));
    if (recibo['referencia'] != null) {
      bytes.addAll(_doblColumna(gen, 'Ref.',
          recibo['referencia'] as String));
    }
    if ((recibo['moneda'] as String) == 'USD') {
      final original = (recibo['monto_original'] as num).toStringAsFixed(2);
      final tasa = (recibo['tasa_conversion'] as num).toStringAsFixed(2);
      bytes.addAll(gen.text('Recibido: US\$$original  (tasa $tasa)',
          styles: const PosStyles(align: PosAlign.left)));
    }
    bytes.addAll(gen.feed(1));

    // Total pagado — destacado.
    bytes.addAll(gen.row([
      PosColumn(
        text: 'PAGADO',
        width: 6,
        styles: const PosStyles(bold: true, height: PosTextSize.size2),
      ),
      PosColumn(
        text: _cordobas(recibo['monto_cordobas'] as num),
        width: 6,
        styles: const PosStyles(
            bold: true, align: PosAlign.right, height: PosTextSize.size2),
      ),
    ]));

    // Pie libre.
    if (pieRecibo != null && pieRecibo.isNotEmpty) {
      bytes.addAll(gen.hr());
      bytes.addAll(gen.text(pieRecibo,
          styles: const PosStyles(align: PosAlign.center)));
    }

    if (esReimpresion) {
      bytes.addAll(gen.feed(1));
      bytes.addAll(gen.text('*** REIMPRESIÓN ***',
          styles: const PosStyles(align: PosAlign.center, bold: true)));
    }

    bytes.addAll(gen.feed(2));
    bytes.addAll(gen.cut());
    return bytes;
  }

  /// Renglón de dos columnas: label izquierdo + valor a la derecha.
  List<int> _doblColumna(Generator gen, String label, String valor) {
    return gen.row([
      PosColumn(
        text: label,
        width: 4,
        styles: const PosStyles(align: PosAlign.left),
      ),
      PosColumn(
        text: valor,
        width: 8,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);
  }

  String _cordobas(num n) =>
      NumberFormat.currency(locale: 'es_NI', symbol: 'C\$', decimalDigits: 2)
          .format(n);
}
