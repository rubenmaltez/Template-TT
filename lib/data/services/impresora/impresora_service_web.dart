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
  }) async {
    throw UnsupportedError('Impresión BT no disponible en web');
  }

  Future<bool> imprimirPrueba({
    required String macImpresora,
    required int anchoMm,
  }) async {
    throw UnsupportedError('Impresión BT no disponible en web');
  }
}
