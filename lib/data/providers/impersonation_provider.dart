import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;
import 'db_epoch_provider.dart';

/// Stream que indica si el super_admin está impersonando un tenant.
/// Retorna el tenant_id impersonado o null si no hay impersonación activa.
///
/// Lee de la tabla `super_admin_impersonation` en el SQLite local
/// (sincronizada por PowerSync vía el bucket `super_admin_self`).
///
/// Para users normales, el query retorna vacío (no tienen rows en
/// esta tabla) → null → sin efecto.
///
/// **No tiene funciones de enter/exit**: toda la lógica de escribir
/// la tabla + audit_log vive en `ImpersonationService`. Un solo
/// write path garantiza que toda impersonación queda auditada.
final impersonatedTenantIdProvider = StreamProvider<String?>((ref) async* {
  ref.watch(dbEpochProvider); // recrea al cambiar de DB (#7)
  yield* ps.db
      .watch('SELECT tenant_id FROM super_admin_impersonation LIMIT 1')
      .map((rows) =>
          rows.isEmpty ? null : rows.first['tenant_id'] as String?);
});

/// True si el super_admin está impersonando un tenant ahora mismo.
///
/// Usado para DESHABILITAR las acciones de campo (cobro / cargo manual /
/// registrar visita) mientras se impersona (#9): esos write-paths atribuyen
/// `cobrador_id`/`tenant_id` a la fila real del super_admin (tenant System),
/// no al tenant impersonado, lo que generaría pagos/recibos huérfanos en
/// System y rompería los invariantes de dinero. El super_admin impersona para
/// VER/GESTIONAR; la cobranza de campo la hace el cobrador del ISP.
final estaImpersonandoProvider = Provider<bool>((ref) {
  return ref.watch(impersonatedTenantIdProvider).valueOrNull != null;
});
