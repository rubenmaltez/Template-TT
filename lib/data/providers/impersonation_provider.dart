import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;

/// Stream que indica si el super_admin está impersonando un tenant.
/// Retorna el tenant_id impersonado o null si no hay impersonación activa.
///
/// Lee de la tabla `super_admin_impersonation` en el SQLite local
/// (sincronizada por PowerSync vía el bucket `super_admin_self`).
///
/// Para users normales, el query retorna vacío (no tienen rows en
/// esta tabla) → null → sin efecto.
final impersonatedTenantIdProvider = StreamProvider<String?>((ref) async* {
  yield* ps.db
      .watch('SELECT tenant_id FROM super_admin_impersonation LIMIT 1')
      .map((rows) =>
          rows.isEmpty ? null : rows.first['tenant_id'] as String?);
});

/// Inicia impersonación de un tenant. Escribe un INSERT en la tabla
/// `super_admin_impersonation` vía PowerSync (que sube a Postgres
/// por el CRUD queue normal). El bucket `impersonated_tenant` se
/// re-evalúa y entrega la data del tenant.
///
/// Después del insert, desconectamos y reconectamos PowerSync para
/// forzar la re-evaluación de los bucket parameters — sin esto,
/// PowerSync no descarga la data del nuevo tenant hasta el próximo
/// checkpoint natural (que puede tardar).
///
/// Retorna cuando PowerSync reconectó (no necesariamente cuando la
/// data del tenant ya llegó — eso lo maneja el UI via los providers
/// normales).
Future<void> startImpersonation(String tenantId) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) {
    throw StateError('No hay sesión activa');
  }

  // UPSERT: si ya estaba impersonando otro tenant, lo reemplaza.
  // PowerSync SQLite → CRUD queue → Postgres upsert (ON CONFLICT
  // (user_id) DO UPDATE por el PK).
  await ps.db.execute(
    '''
    INSERT OR REPLACE INTO super_admin_impersonation (id, user_id, tenant_id, started_at)
    VALUES (?, ?, ?, ?)
    ''',
    [userId, userId, tenantId, DateTime.now().toUtc().toIso8601String()],
  );

  // Reconectar PowerSync para que re-evalúe los bucket parameters.
  // El bucket `impersonated_tenant` ahora tiene un tenant_id → va a
  // descargar la data de ese tenant.
  debugPrint('[IMPERSONATE] startImpersonation: reconnecting PowerSync '
      'for tenant $tenantId');
  await ps.disconnectPowerSync();
  await ps.connectPowerSync();
  debugPrint('[IMPERSONATE] startImpersonation: reconnect done');
}

/// Detiene la impersonación. Borra la row de la tabla y reconecta
/// PowerSync para que descarte el bucket `impersonated_tenant`.
Future<void> stopImpersonation() async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return;

  await ps.db.execute(
    'DELETE FROM super_admin_impersonation WHERE id = ?',
    [userId],
  );

  debugPrint('[IMPERSONATE] stopImpersonation: reconnecting PowerSync');
  await ps.disconnectPowerSync();
  await ps.connectPowerSync();
  debugPrint('[IMPERSONATE] stopImpersonation: reconnect done');
}
