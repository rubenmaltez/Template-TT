import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;
import '../models/cobrador.dart';

/// Cobrador (usuario actual) sincronizado desde el SQLite local.
/// Reacciona a cambios en la fila (ej. admin actualiza prefijo_recibo).
final cobradorActualProvider = StreamProvider<Cobrador?>((ref) async* {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    yield null;
    return;
  }

  await for (final rows in ps.db.watch(
    'SELECT * FROM cobradores WHERE id = ?',
    parameters: [user.id],
  )) {
    if (rows.isEmpty) {
      yield null;
    } else {
      yield Cobrador.fromRow(rows.first);
    }
  }
});

/// Tenant del cobrador actual (helper). Devuelve null si no hay sesión.
final tenantIdProvider = Provider<String?>((ref) {
  return ref.watch(cobradorActualProvider).valueOrNull?.tenantId;
});
