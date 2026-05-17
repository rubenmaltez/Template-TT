import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Foto del cliente: el admin trabaja online primariamente, así que la
/// subida es síncrona (no offline-first como comprobante).
/// Convención: bucket `fotos-clientes`, path `{tenant_id}/cli/{cliente_id}.jpg`.
class FotoClienteService {
  FotoClienteService(this._supabase);
  final SupabaseClient _supabase;
  final _picker = ImagePicker();
  static const _bucket = 'fotos-clientes';

  /// Toma una foto y la sube. Devuelve el path remoto o null si falló o el
  /// usuario canceló. Lanza si Storage rechaza.
  Future<String?> capturarYSubir({
    required ImageSource source,
    required String tenantId,
    required String clienteId,
  }) async {
    final raw = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    if (raw == null) return null;

    final bytes = await raw.readAsBytes();
    final path = '$tenantId/cli/$clienteId.jpg';
    await _supabase.storage.from(_bucket).uploadBinary(
          path,
          bytes,
          fileOptions:
              const FileOptions(upsert: true, contentType: 'image/jpeg'),
        );
    return path;
  }

  /// URL firmada de la foto (TTL 1h) para mostrar en UI.
  Future<String?> urlFirmada(String pathRemoto) async {
    try {
      return await _supabase.storage
          .from(_bucket)
          .createSignedUrl(pathRemoto, 3600);
    } catch (e) {
      if (kDebugMode) debugPrint('FotoCliente urlFirmada: $e');
      return null;
    }
  }

  /// Bytes directos (alternativa cuando se acaba de subir y queremos
  /// preview inmediato sin esperar URL firmada).
  Future<Uint8List?> bytes(ImageSource source) async {
    final raw = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    if (raw == null) return null;
    return raw.readAsBytes();
  }
}
