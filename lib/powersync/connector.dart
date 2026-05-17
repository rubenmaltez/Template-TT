import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// Conector entre PowerSync y Supabase.
///
///  - `fetchCredentials` pide el JWT firmado a la Edge Function `powersync-auth`
///    (autenticada con la sesión Supabase actual).
///  - `uploadData` drena la crud queue local hacia Postgres vía supabase_flutter.
///    Si una operación falla, la transacción no se completa y PowerSync reintenta.
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector(this._supabase);

  final SupabaseClient _supabase;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final session = _supabase.auth.currentSession;
    if (session == null) return null;

    final response = await _supabase.functions.invoke('powersync-auth');
    final data = response.data;
    if (data is! Map || data['token'] is! String) {
      throw StateError('powersync-auth devolvió payload inválido: $data');
    }

    return PowerSyncCredentials(
      endpoint: Env.powersyncUrl,
      token: data['token'] as String,
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getCrudBatch();
    if (transaction == null) return;

    for (final op in transaction.crud) {
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
    }

    await transaction.complete();
  }
}
