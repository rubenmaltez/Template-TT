import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../data/models/error_log_entry.dart';
import '../data/services/error_log_service.dart';
import '../data/services/rechazos_sync_service.dart';

/// Conector entre PowerSync y Supabase usando **Supabase Auth directo**.
///
///  - `fetchCredentials`: devuelve el access token de la sesión Supabase actual.
///  - `uploadData`: drena la crud queue local hacia Postgres vía supabase_flutter.
///
/// **Manejo de errores no-retryables** (E2E bug #2):
/// Si un INSERT/UPDATE falla con un error de cliente (constraint violation,
/// trigger reject, RLS denied — típicamente status <500), el error NO es
/// retryable. Reintentar infinitamente bloquea todo el sync. En vez de
/// `rethrow`, logueamos el error, emitimos al stream `uploadErrors` para
/// que la UI lo muestre, y avanzamos al siguiente item del batch.
///
/// Errores de server (500, network timeout) SÍ se rethrolean para que
/// PowerSync reintente automáticamente.
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector(this._supabase);

  final SupabaseClient _supabase;

  /// Stream de errores de CRUD upload que la UI puede watchear para
  /// mostrar SnackBars cuando un write local fue rechazado por el server.
  final _uploadErrors = StreamController<CrudUploadError>.broadcast();
  Stream<CrudUploadError> get uploadErrors => _uploadErrors.stream;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final session = _supabase.auth.currentSession;
    if (session == null) return null;

    return PowerSyncCredentials(
      endpoint: Env.powersyncUrl,
      token: session.accessToken,
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getCrudBatch();
    if (transaction == null) return;

    try {
      for (final op in transaction.crud) {
        try {
          final table = _supabase.from(op.table);
          switch (op.op) {
            case UpdateType.put:
              await table.upsert({'id': op.id, ...?op.opData});
              break;
            case UpdateType.patch:
              if (op.opData != null) {
                await table.update(op.opData!).eq('id', op.id);
              }
              break;
            case UpdateType.delete:
              await table.delete().eq('id', op.id);
              break;
          }
        } on PostgrestException catch (e) {
          if (_isNonRetryable(e)) {
            // El write local fue RECHAZADO por el server (constraint/RLS/
            // trigger). No es retryable: lo saltamos para no trabar la cola.
            // OJO: el dato local queda DIVERGENTE del server (que no lo aceptó).
            // Triple rastro (audit 2026-06-11 #5): SnackBar inmediato
            // (uploadErrors), aviso PERSISTENTE en el Perfil del usuario
            // (RechazosSyncService) y error_logs con el opData completo —
            // único registro del contenido para reconstruir el write a mano.
            final detalle = '${op.op.name.toUpperCase()} ${op.table}/${op.id}'
                ' — ${e.code ?? '?'} ${e.message}';
            debugPrint('[CRUD] Non-retryable rejected: $detalle');
            _uploadErrors.add(CrudUploadError(
              table: op.table,
              id: op.id,
              message: e.message,
              codigo: e.code,
            ));
            final ahoraUtc = DateTime.now().toUtc();
            unawaited(RechazosSyncService.instance.registrar(RechazoSync(
              id: '${ahoraUtc.microsecondsSinceEpoch}-${op.id}',
              tabla: op.table,
              registroId: op.id,
              op: op.op.name,
              codigo: e.code,
              mensaje: e.message,
              fechaUtcIso: ahoraUtc.toIso8601String(),
              data: op.opData,
            )));
            unawaited(ErrorLogService.instance.record(
              error: 'CRUD rejected (local diverge): $detalle'
                  ' — opData: ${jsonEncode(op.opData)}',
              stack: StackTrace.current,
              type: ErrorLogType.zone,
            ));
            continue;
          }
          rethrow;
        }
      }
      await transaction.complete();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PowerSync uploadData falló: $e\n$st');
      }
      rethrow;
    }
  }

  bool _isNonRetryable(PostgrestException e) => esCodigoNoRetryable(e.code);
}

/// Clasifica el código de error de un upload rechazado (pública para tests).
///
/// `true` = error PERMANENTE de cliente: el server NUNCA va a aceptar este
/// write tal como está. Se descarta de la cola (con aviso + registro) para
/// no trabar el sync. `false` = se reintenta.
///
/// La regla es ALLOWLIST de clases SQLSTATE permanentes — todo lo demás se
/// trata como transitorio, porque descartar un write válido pierde plata
/// (un cobro offline que el server nunca recibe), mientras que reintentar
/// de más solo demora la cola. Audit 2026-06-11 (#1): la versión anterior
/// clasificaba por prefijos `'P'`/`'4'` y descartaba transitorios reales:
/// PGRST301 (JWT expirado justo al recuperar señal, antes del refresh),
/// PGRST000/002 (DB no disponible) y códigos HTTP tipo 429 (rate limit).
///
///   - Permanentes: 23xxx (constraint), 42xxx (schema/permiso RLS),
///     22xxx (formato de dato) y P0001 (RAISE EXCEPTION de triggers de
///     negocio). Solo SQLSTATE reales (5 chars) — un '429' HTTP no matchea.
///   - Retryables: PGRST*, códigos HTTP, clase 40 (serialization/deadlock)
///     y cualquier desconocido. OJO: un permanente "raro" (p.ej. PGRST204
///     por columna que falta en el server) BLOQUEA la cola reintentando —
///     a propósito: preserva el dato y se destraba al correr la migración
///     faltante, en vez de perder el write para siempre.
bool esCodigoNoRetryable(String? code) {
  if (code == null) return false;
  if (code == 'P0001') return true;
  if (code.length != 5) return false;
  return code.startsWith('23') ||
      code.startsWith('42') ||
      code.startsWith('22');
}

/// Error de CRUD upload surfaceado a la UI.
class CrudUploadError {
  const CrudUploadError({
    required this.table,
    required this.id,
    required this.message,
    this.codigo,
  });

  final String table;
  final String id;
  final String message;

  /// Código SQLSTATE/PostgREST del rechazo — los shells lo usan para
  /// humanizar el mensaje (ver `humanizarRechazoSync`).
  final String? codigo;
}
