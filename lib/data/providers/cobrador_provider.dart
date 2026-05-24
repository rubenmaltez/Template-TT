import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;
import '../models/cobrador.dart';
import 'impersonation_provider.dart';

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

/// Tenant efectivo: el impersonado si el super_admin está dentro de
/// un tenant, sino el del cobrador actual. Usar esto en vez de
/// `cobrador.tenantId` para operaciones que deben respetar la
/// impersonación (INSERT/UPDATE, queries scoped por tenant, etc.).
///
/// Para users normales (admin/cobrador), impersonation es siempre
/// null → retorna el tenant real del cobrador. Sin efecto.
final tenantIdProvider = Provider<String?>((ref) {
  final impersonated = ref.watch(impersonatedTenantIdProvider).valueOrNull;
  if (impersonated != null) return impersonated;
  return ref.watch(cobradorActualProvider).valueOrNull?.tenantId;
});
