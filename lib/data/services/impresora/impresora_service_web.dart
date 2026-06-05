import 'dart:typed_data';

import 'impresora_diagnostico.dart';

/// Stub web: impresión Bluetooth no aplica en navegador.
class ImpresoraBT {
  /// Nombre de la impresora pareada (vacío en web).
  final String nombre;
  final String mac;

  const ImpresoraBT({required this.nombre, required this.mac});
}

class ImpresoraService {
  /// En web siempre es false — no hay BT.
  bool get soportado => false;

  Future<bool> isBluetoothEnabled() async => false;

  Future<List<ImpresoraBT>> listarPareadas() async => const [];

  /// Espeja la firma del service io para que el conditional import compile.
  /// BT no aplica en web (se usa el PDF descargable), así que tira siempre.
  Future<bool> imprimirImagen({
    required String macImpresora,
    required Uint8List pngBytes,
    required int anchoMm,
  }) async {
    throw UnsupportedError('Impresión BT no disponible en web');
  }

  Future<bool> imprimirPrueba({
    required String macImpresora,
    required int anchoMm,
  }) async {
    throw UnsupportedError('Impresión BT no disponible en web');
  }

  /// Espeja la firma del service io. Diagnóstico solo aplica en mobile.
  Future<DiagnosticoImpresion> diagnosticar({
    required Uint8List pngBytes,
    required int anchoMm,
  }) async {
    throw UnsupportedError('Diagnóstico de impresión no disponible en web');
  }
}
