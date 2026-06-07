import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../data/models/error_log_entry.dart';
import '../data/services/error_log_service.dart';

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
            // Lo surfaceamos a la UI (uploadErrors) y lo persistimos en
            // error_logs con el TIPO de op + código para diagnóstico; un próximo
            // write sobre la misma fila lo reconcilia o el admin lo corrige.
            final detalle = '${op.op.name.toUpperCase()} ${op.table}/${op.id}'
                ' — ${e.code ?? '?'} ${e.message}';
            debugPrint('[CRUD] Non-retryable rejected: $detalle');
            _uploadErrors.add(CrudUploadError(
              table: op.table,
              id: op.id,
              message: e.message,
            ));
            unawaited(ErrorLogService.instance.record(
              error: 'CRUD rejected (local diverge): $detalle',
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

  bool _isNonRetryable(PostgrestException e) {
    final code = e.code;
    if (code == null) return false;
    // Postgres error codes: P0001 = raise_exception (triggers),
    // 23xxx = integrity constraint violations, 42xxx = syntax/access.
    // Todos son errores de cliente, no retryables.
    if (code.startsWith('P') || code.startsWith('2') || code.startsWith('4')) {
      return true;
    }
    return false;
  }
}

/// Error de CRUD upload surfaceado a la UI.
class CrudUploadError {
  const CrudUploadError({
    required this.table,
    required this.id,
    required this.message,
  });

  final String table;
  final String id;
  final String message;
}
