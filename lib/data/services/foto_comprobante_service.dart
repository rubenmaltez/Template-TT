import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;

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
class FotoComprobanteService {
  FotoComprobanteService(this._supabase);
  final SupabaseClient _supabase;
  final _picker = ImagePicker();
  static const _bucket = 'comprobantes-pago';
  static const _prefijoLocal = 'local://';

  /// Toma una foto con la cámara o la elige de galería, la comprime y la
  /// guarda en disco local. Devuelve el path con prefijo `local://`.
  /// Devuelve null si el usuario cancela.
  Future<String?> capturar({required ImageSource source}) async {
    final XFile? raw = await _picker.pickImage(
      source: source,
      imageQuality: 70, // Comprimir a JPEG ~70% calidad
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (raw == null) return null;

    final dir = await _comprobantesDir();
    final nombre = '${const Uuid().v4()}.jpg';
    final destino = '${dir.path}/$nombre';
    final bytes = await raw.readAsBytes();
    await File(destino).writeAsBytes(bytes, flush: true);

    return '$_prefijoLocal$nombre';
  }

  /// Resuelve un path almacenado en `pagos.foto_comprobante_path` a un
  /// archivo local si existe. Devuelve null si el path es remoto o no
  /// se encuentra.
  Future<File?> archivoLocal(String? pathBd) async {
    if (pathBd == null || !pathBd.startsWith(_prefijoLocal)) return null;
    final nombre = pathBd.substring(_prefijoLocal.length);
    final dir = await _comprobantesDir();
    final f = File('${dir.path}/$nombre');
    return f.existsSync() ? f : null;
  }

  /// Sube las fotos de todos los pagos cuyo `foto_comprobante_path`
  /// arranca con `local://`. Pensado para llamarse cuando hay conexión.
  /// Devuelve cantidad de fotos subidas.
  Future<int> sincronizarPendientes() async {
    final pendientes = await ps.db.getAll(
      "SELECT id, tenant_id, foto_comprobante_path "
      "FROM pagos WHERE foto_comprobante_path LIKE 'local://%'",
    );

    var subidas = 0;
    for (final row in pendientes) {
      final pagoId = row['id'] as String;
      final tenantId = row['tenant_id'] as String;
      final pathLocal = row['foto_comprobante_path'] as String;
      try {
        final file = await archivoLocal(pathLocal);
        if (file == null) {
          // El archivo local desapareció — limpiar referencia.
          await ps.db.execute(
            "UPDATE pagos SET foto_comprobante_path = NULL WHERE id = ?",
            [pagoId],
          );
          continue;
        }

        final pathRemoto = '$tenantId/comp/$pagoId.jpg';
        await _supabase.storage.from(_bucket).uploadBinary(
              pathRemoto,
              await file.readAsBytes(),
              fileOptions: const FileOptions(
                upsert: true,
                contentType: 'image/jpeg',
              ),
            );

        await ps.db.execute(
          "UPDATE pagos SET foto_comprobante_path = ? WHERE id = ?",
          [pathRemoto, pagoId],
        );
        // Best-effort: borrar el archivo local liberando espacio.
        try {
          await file.delete();
        } catch (_) {}

        subidas++;
      } catch (e) {
        if (kDebugMode) debugPrint('Foto $pagoId no subió aún: $e');
        // Continuar con la siguiente; reintenta en próximo sync.
      }
    }
    return subidas;
  }

  /// Cuenta fotos pendientes de subida (para indicadores UI).
  Future<int> contarPendientes() async {
    final rows = await ps.db.getAll(
      "SELECT COUNT(*) AS n FROM pagos "
      "WHERE foto_comprobante_path LIKE 'local://%' AND anulado = 0",
    );
    return (rows.first['n'] as num).toInt();
  }

  /// Genera URL firmada para mostrar la foto desde Storage. Expira en 1h.
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

  Future<Directory> _comprobantesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/foto_comprobante');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }
}
