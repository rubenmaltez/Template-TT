import 'package:supabase_flutter/supabase_flutter.dart';

import '../../powersync/db.dart' as ps;

/// Servicio para entrar/salir del modo impersonación de tenant.
///
/// Cuando el super_admin "entra" a un tenant:
///   1. UPSERT en `super_admin_impersonation` con el tenant elegido.
///   2. Registra en `audit_log`.
///   3. Disconnect + reconnect PowerSync (re-evalúa sync rules →
///      descarga la data del tenant impersonado).
///
/// Cuando "sale":
///   1. DELETE de `super_admin_impersonation`.
///   2. Registra en `audit_log`.
///   3. Disconnect + reconnect PowerSync (vuelve a System).
class ImpersonationService {
  ImpersonationService(this._supabase);
  final SupabaseClient _supabase;

  /// Entra al tenant indicado. El sync gate se encarga de mostrar
  /// progreso mientras PowerSync descarga la data.
  Future<void> enter({
    required String tenantId,
    required String tenantNombre,
  }) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) throw StateError('No hay sesión activa');

    // UPSERT: si ya estaba impersonando otro tenant, reemplaza.
    await _supabase.from('super_admin_impersonation').upsert({
      'user_id': userId,
      'tenant_id': tenantId,
    });

    // Audit trail.
    await _supabase.from('audit_log').insert({
      'tenant_id': tenantId,
      'tabla': 'super_admin_impersonation',
      'registro_id': userId,
      'campo': 'impersonation',
      'valor_anterior': null,
      'valor_nuevo': {
        'action': 'impersonate_start',
        'tenant_nombre': tenantNombre,
      },
      'user_id': userId,
      'user_rol': 'super_admin',
    });

    // Reconnect PowerSync para que re-evalúe sync rules con el nuevo
    // tenant. Esto dispara el sync gate automáticamente.
    await ps.disconnectPowerSync();
    await ps.connectPowerSync();
  }

  /// Sale del modo impersonación. Vuelve al tenant System.
  Future<void> exit() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    // Leer tenant actual para el audit trail.
    final current = await _supabase
        .from('super_admin_impersonation')
        .select('tenant_id')
        .eq('user_id', userId)
        .maybeSingle();

    await _supabase
        .from('super_admin_impersonation')
        .delete()
        .eq('user_id', userId);

    if (current != null) {
      await _supabase.from('audit_log').insert({
        'tenant_id': current['tenant_id'],
        'tabla': 'super_admin_impersonation',
        'registro_id': userId,
        'campo': 'impersonation',
        'valor_anterior': {
          'action': 'impersonate_end',
        },
        'valor_nuevo': null,
        'user_id': userId,
        'user_rol': 'super_admin',
      });
    }

    await ps.disconnectPowerSync();
    await ps.connectPowerSync();
  }
}
