import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import 'foto_local_storage.dart';

/// Manejo de fotos del comprobante de pago.
///
/// Flujo offline-first:
///   1. capturar(): toma/elige foto, la comprime y la guarda en disco local
///      con un nombre persistente. Devuelve un path con prefijo `local://`
///      que se guarda en `pagos.foto_comprobante_path`.
///   2. Cuando PowerSync vuelve a estar online, sincronizarPendientes()
///      barre los pagos con path `local://*`, los sube a Storage y
///      actualiza el path al definitivo.
///
/// El bucket Storage es `comprobantes-pago` y la convención de path final
/// es `{tenant_id}/comp/{pago_id}.jpg` (ver migración 0019).
///
/// Cross-platform: en web el storage local no aplica (no hay filesystem
/// persistente) — la captura no funciona ahí, sólo la VISUALIZACIÓN remota.
class FotoComprobanteService {
  FotoComprobanteService(this._supabase);
  final SupabaseClient _supabase;
  final _picker = ImagePicker();
  static const _bucket = 'comprobantes-pago';
  static const _prefijoLocal = 'local://';

  // Flag de corrida única ESTÁTICO: compartido entre TODAS las instancias
  // (worker en main.dart y el provider Riverpod podrían instanciar el
  // servicio por separado). Previene doble upload del mismo path.
  static bool _sincronizando = false;

  /// Toma una foto con cámara o galería, la comprime y la guarda en disco
  /// local. Devuelve el path con prefijo `local://`. Null si el usuario
  /// canceló o si la plataforma no soporta storage local.
  Future<String?> capturar({required ImageSource source}) async {
    final XFile? raw = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (raw == null) return null;

    final bytes = await raw.readAsBytes();
    final nombre = '${const Uuid().v4()}.jpg';
    final ok = await FotoLocalStorage.save(bytes, nombre);
    if (!ok) return null;

    return '$_prefijoLocal$nombre';
  }

  /// Resuelve un path almacenado en `pagos.foto_comprobante_path` a bytes
  /// si existe localmente. Devuelve null si el path es remoto o no existe.
  ///
  /// Valida que el nombre sea un UUID + extensión sin path traversal.
  Future<Uint8List?> bytesLocal(String? pathBd) async {
    if (pathBd == null || !pathBd.startsWith(_prefijoLocal)) return null;
    final nombre = pathBd.substring(_prefijoLocal.length);
    if (!_nombreSeguro(nombre)) return null;
    return FotoLocalStorage.read(nombre);
  }

  /// Sube las fotos pendientes (filtra `anulado = 0`).
  /// Lock de corrida única: si ya está sincronizando, retorna 0 sin hacer
  /// nada — compatible con disparos simultáneos desde worker y UI.
  Future<int> sincronizarPendientes() async {
    if (_sincronizando) return 0;
    _sincronizando = true;
    try {
      return await _sincronizarImpl();
    } finally {
      _sincronizando = false;
    }
  }

  Future<int> _sincronizarImpl() async {
    final pendientes = await ps.db.getAll(
      "SELECT id, tenant_id, foto_comprobante_path "
      "FROM pagos "
      "WHERE foto_comprobante_path LIKE 'local://%' AND anulado = 0",
    );

    var subidas = 0;
    for (final row in pendientes) {
      final pagoId = row['id'] as String;
      final tenantId = row['tenant_id'] as String;
      final pathLocal = row['foto_comprobante_path'] as String;
      final nombre = pathLocal.substring(_prefijoLocal.length);

      if (!_nombreSeguro(nombre)) {
        // Path sospechoso (vino mal de otro dispositivo o admin malicioso).
        await ps.db.execute(
          "UPDATE pagos SET foto_comprobante_path = NULL WHERE id = ?",
          [pagoId],
        );
        continue;
      }

      try {
        final bytes = await FotoLocalStorage.read(nombre);
        if (bytes == null) {
          // El archivo local desapareció (otro dispositivo, reinstall, etc.).
          // Limpiar referencia.
          await ps.db.execute(
            "UPDATE pagos SET foto_comprobante_path = NULL "
            "WHERE id = ? AND foto_comprobante_path LIKE 'local://%'",
            [pagoId],
          );
          continue;
        }

        final pathRemoto = '$tenantId/comp/$pagoId.jpg';
        await _supabase.storage.from(_bucket).uploadBinary(
              pathRemoto,
              bytes,
              fileOptions: const FileOptions(
                upsert: true,
                contentType: 'image/jpeg',
              ),
            );

        // El WHERE protege contra una segunda corrida que ya hubiera
        // actualizado el path.
        await ps.db.execute(
          "UPDATE pagos SET foto_comprobante_path = ? "
          "WHERE id = ? AND foto_comprobante_path LIKE 'local://%'",
          [pathRemoto, pagoId],
        );
        await FotoLocalStorage.delete(nombre);
        subidas++;
      } catch (e) {
        if (kDebugMode) debugPrint('Foto $pagoId no subió aún: $e');
        // Continuar — reintenta en próximo sync.
      }
    }
    return subidas;
  }

  /// Genera URL firmada para mostrar la foto desde Storage. TTL 1h.
  Future<String?> urlFirmada(String pathRemoto) async {
    try {
      return await _supabase.storage
          .from(_bucket)
          .createSignedUrl(pathRemoto, 3600);
    } catch (e) {
      if (kDebugMode) debugPrint('urlFirmada: $e');
      return null;
    }
  }

  /// Garbage collection: borra archivos locales que no tienen referencia
  /// activa en `pagos.foto_comprobante_path`. Casos típicos: cobrador
  /// canceló un cobro tras adjuntar foto, o el pago ya se sincronizó al
  /// path remoto y el archivo local quedó.
  Future<int> limpiarHuerfanos() async {
    final archivos = await FotoLocalStorage.listAll();
    if (archivos.isEmpty) return 0;

    final refs = await ps.db.getAll(
      "SELECT foto_comprobante_path FROM pagos "
      "WHERE foto_comprobante_path LIKE 'local://%'",
    );
    final usados = refs
        .map((r) => (r['foto_comprobante_path'] as String).substring(_prefijoLocal.length))
        .toSet();

    var borrados = 0;
    for (final f in archivos) {
      if (!usados.contains(f)) {
        if (await FotoLocalStorage.delete(f)) borrados++;
      }
    }
    return borrados;
  }

  /// Nombre seguro: UUID v4 + extensión, sin separadores ni `..`.
  bool _nombreSeguro(String nombre) {
    if (nombre.contains('/') || nombre.contains('\\') || nombre.contains('..')) {
      return false;
    }
    // UUID + .jpg típicamente 40 chars, dejamos margen.
    return nombre.length >= 5 && nombre.length <= 64;
  }
}
