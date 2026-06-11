import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'logo_local_storage.dart';

/// Caché OFFLINE del logo de la empresa para la impresora térmica.
///
/// La impresión es 100% offline (Bluetooth local, sin red). El logo, en
/// cambio, vive en Storage de Supabase. Para que la térmica pueda imprimirlo
/// sin conexión, el logo se DESCARGA y se guarda en disco local cuando hay
/// red (`refrescarLogo`), y al imprimir se LEE del disco (`leerLogoCacheado`)
/// — esa lectura nunca toca la red.
///
/// Flujo:
///   1. Hay conexión → `refrescarLogo(tenantId, logoPath)` baja el logo del
///      bucket `logos-empresa` y lo persiste como `logo_<tenantId>.png` en el
///      directorio de documentos de la app.
///   2. El cobrador queda offline → `leerLogoCacheado(tenantId)` devuelve los
///      bytes del disco (o null si nunca se cacheó). Sin red.
///   3. La térmica decodifica esos bytes y los emite como raster.
///
/// Si nunca se cacheó (nunca hubo red, o el tenant no tiene logo), el logo
/// simplemente no se imprime — el recibo sale igual sin logo.
///
/// Cross-platform: en web no hay filesystem persistente (el storage backend
/// es un stub no-op), así que el cache no aplica. En web el recibo se imprime
/// como PDF con el logo embebido por otra vía (no por esta caché).
class LogoCacheService {
  LogoCacheService([SupabaseClient? supabase])
      : _supabase = supabase ?? Supabase.instance.client;
  final SupabaseClient _supabase;

  static const _bucket = 'logos-empresa';

  /// Refresca el cache local del logo. Requiere RED (descarga del bucket).
  ///
  /// - Si `logoPath` es null/vacío → no hay logo configurado: no hace nada
  ///   (deja el cache anterior intacto, sea cual sea).
  /// - Si la descarga falla (sin red, error de Storage) → silencio: se
  ///   conserva el cache previo. NUNCA lanza ni bloquea el flujo del caller.
  ///
  /// Llamar cuando hay conexión (ej. en el listener `status.connected` de
  /// main.dart) para que el logo quede disponible ANTES de ir offline.
  Future<void> refrescarLogo({
    required String tenantId,
    required String? logoPath,
  }) async {
    if (tenantId.isEmpty) return;
    if (logoPath == null || logoPath.isEmpty) return;
    try {
      final bytes = await _supabase.storage.from(_bucket).download(logoPath);
      if (bytes.isEmpty) return;
      // LogoLocalStorage arma el nombre `logo_<tenantId>.png` internamente.
      await LogoLocalStorage.save(bytes, tenantId);
    } catch (e) {
      // Silenciado a propósito: si no se puede bajar, se queda el cache
      // anterior. La impresión offline usa lo que haya en disco.
      if (kDebugMode) debugPrint('LogoCacheService.refrescarLogo: $e');
    }
  }

  /// Lee el logo cacheado del DISCO local. NO toca la red → sirve offline.
  /// Devuelve null si nunca se cacheó (o en web, donde no hay filesystem).
  Future<Uint8List?> leerLogoCacheado(String tenantId) async {
    if (tenantId.isEmpty) return null;
    return LogoLocalStorage.read(tenantId);
  }
}
