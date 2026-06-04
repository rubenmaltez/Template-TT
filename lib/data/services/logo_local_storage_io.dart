import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Almacenamiento local del logo de la empresa cacheado para impresión
/// térmica OFFLINE (mobile/desktop con filesystem). Compañera
/// `logo_local_storage_web.dart` queda como stub (web no imprime en térmica).
///
/// El archivo se guarda como `logo_<tenantId>.png` dentro del directorio
/// de documentos de la app, así sobrevive reinicios y queda disponible sin
/// red al momento de imprimir.
class LogoLocalStorage {
  static const _dirName = 'logo_empresa';

  /// Persiste `bytes` del logo del tenant `tenantId`. Devuelve false si no
  /// se pudo escribir (deja intacto el cache anterior si lo había).
  static Future<bool> save(Uint8List bytes, String tenantId) async {
    if (!_tenantSeguro(tenantId)) return false;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombre(tenantId)}');
      await f.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Lee los bytes del logo cacheado del tenant. Null si no existe (nunca se
  /// cacheó, o el archivo se borró). Solo toca disco — sirve OFFLINE.
  static Future<Uint8List?> read(String tenantId) async {
    if (!_tenantSeguro(tenantId)) return null;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombre(tenantId)}');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Borra el logo cacheado del tenant (ej. el admin quitó el logo).
  static Future<bool> delete(String tenantId) async {
    if (!_tenantSeguro(tenantId)) return false;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_nombre(tenantId)}');
      if (await f.exists()) {
        await f.delete();
        return true;
      }
    } catch (_) {}
    return false;
  }

  static String _nombre(String tenantId) => 'logo_$tenantId.png';

  /// Defensa contra path traversal: el tenantId va en el nombre de archivo.
  /// Es un UUID, así que no debería tener separadores ni `..`.
  static bool _tenantSeguro(String tenantId) {
    if (tenantId.isEmpty) return false;
    return !(tenantId.contains('/') ||
        tenantId.contains('\\') ||
        tenantId.contains('..'));
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
