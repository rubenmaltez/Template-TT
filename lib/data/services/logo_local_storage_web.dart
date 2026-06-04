import 'dart:typed_data';

/// Stub web del cache local del logo. En navegador no hay filesystem
/// persistente ni impresión térmica Bluetooth, así que el cache no aplica:
/// `read` siempre devuelve null y `save`/`delete` son no-ops. El recibo en
/// web se imprime como PDF con el logo embebido por otra vía.
class LogoLocalStorage {
  static Future<bool> save(Uint8List bytes, String tenantId) async => false;

  static Future<Uint8List?> read(String tenantId) async => null;

  static Future<bool> delete(String tenantId) async => false;
}
