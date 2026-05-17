import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// Conector entre PowerSync y Supabase usando **Supabase Auth directo**.
///
///  - `fetchCredentials`: devuelve el access token de la sesión Supabase actual.
///    PowerSync acepta ese JWT porque en el dashboard activamos "Use Supabase Auth".
///    Supabase auto-refresca el token; `currentSession.accessToken` siempre está vigente.
///  - `uploadData`: drena la crud queue local hacia Postgres vía supabase_flutter.
///    Si falla, la transacción no se completa y PowerSync reintenta.
class SupabaseConnector extends PowerSyncBackendConnector {
  SupabaseConnector(this._supabase);

  final SupabaseClient _supabase;

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

    // Las 3 operaciones son idempotentes por id (upsert/update/delete con
    // PK), así que un retry del mismo batch tras un fallo a mitad no causa
    // duplicación. Si falla, no llamamos a complete() y PowerSync reintenta.
    try {
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
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PowerSync uploadData falló: $e\n$st');
      }
      rethrow;
    }
  }
}
