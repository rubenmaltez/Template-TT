import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/audit_entry.dart';
import '../models/cobrador_admin.dart';
import '../models/cobrador_stats.dart';
import '../models/modulo.dart';
import '../models/tenant_admin.dart';

/// Repo del panel /super/*. Habla con Supabase por RPC — no toca el SQLite
/// local. Las tablas modulos / tenant_modulos no se sincronizan al cliente.
class SuperAdminRepo {
  const SuperAdminRepo(this._client);

  final SupabaseClient _client;

  /// Helper para invocar una Edge Function y devolver el body parseado
  /// con manejo unificado de errores. Las funciones del panel siempre
  /// devuelven {ok, error?, ...}; este helper extrae el mensaje real
  /// del campo `error` tanto en respuestas 200-ok=false como en
  /// FunctionException (status != 200), evitando que el caller tenga
  /// que ver el wrapper feo 'FunctionException(status: 409, details:…)'.
  Future<Map<String, dynamic>> _invokeFn(
    String name, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final res = await _client.functions.invoke(name, body: body);
      final data = res.data as Map<String, dynamic>?;
      if (data == null) {
        throw Exception('Sin respuesta del servidor');
      }
      if (data['ok'] != true) {
        throw Exception(
            (data['error'] as String?) ?? 'Error desconocido');
      }
      return data;
    } on FunctionException catch (e) {
      // Edge Function devolvió 4xx/5xx — el body parseado vive en
      // e.details. Extraemos el campo 'error' si está; sino fallback al
      // status para no mostrar string vacío.
      final det = e.details;
      String? mensaje;
      if (det is Map && det['error'] != null) {
        mensaje = det['error'].toString();
      }
      throw Exception(mensaje ?? 'Error ${e.status}');
    }
  }

  Future<List<Modulo>> listModulos() async {
    final res = await _client.rpc('list_modulos') as List<dynamic>;
    return res
        .map((e) => Modulo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Crea un tenant + invita al admin en una sola operación atómica
  /// (best-effort). Si el invite falla tras crear el tenant, la Edge
  /// Function intenta rollback. Devuelve el id del tenant nuevo para
  /// que el caller pueda navegar al detalle.
  ///
  /// Si `enviarEmail` es false, no se envía email — la Edge Function
  /// crea al admin con una password aleatoria y la devuelve en
  /// `adminPassword` para que el super_admin la comparta por otro
  /// canal (WhatsApp, etc.). Útil cuando el proveedor SMTP está en
  /// sandbox o no autoriza el destinatario. El admin se loguea con
  /// email+password normal por /login.
  Future<
      ({
        String tenantId,
        String adminUserId,
        String adminEmail,
        String? adminPassword,
      })> crearTenant({
    required String nombre,
    required String adminEmail,
    required String adminNombre,
    String? adminTelefono,
    List<String> modulosExtra = const [],
    String? redirectTo,
    bool enviarEmail = true,
  }) async {
    final data = await _invokeFn('crear-tenant', body: {
      'tenant_nombre': nombre,
      'admin_email': adminEmail,
      'admin_nombre': adminNombre,
      if (adminTelefono != null && adminTelefono.isNotEmpty)
        'admin_telefono': adminTelefono,
      if (modulosExtra.isNotEmpty) 'modulos_extra': modulosExtra,
      if (redirectTo != null) 'redirect_to': redirectTo,
      // Mando el flag siempre (no condicional) — el server tiene su
      // propio default true, pero ser explícito previene ambigüedad si
      // cambia ese default en el futuro.
      'enviar_email': enviarEmail,
    });
    return (
      tenantId: data['tenant_id'] as String,
      adminUserId: data['admin_user_id'] as String,
      // Fallback al email que mandamos: si una Edge Function stale
      // (deploy roto, versión vieja) no eco el campo, evitamos el
      // crash por cast no-nulo.
      adminEmail: (data['admin_email'] as String?) ?? adminEmail,
      adminPassword: data['admin_password'] as String?,
    );
  }

  Future<List<TenantAdmin>> listTenants() async {
    final res = await _client.rpc('list_tenants_admin') as List<dynamic>;
    return res
        .map((e) => TenantAdmin.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> setTenantModulo({
    required String tenantId,
    required String modulo,
    required bool habilitado,
  }) async {
    await _client.rpc('set_tenant_modulo', params: {
      'p_tenant_id': tenantId,
      'p_modulo': modulo,
      'p_habilitado': habilitado,
    });
  }

  Future<List<CobradorAdmin>> listCobradoresTenant(String tenantId) async {
    final res = await _client.rpc('list_cobradores_tenant', params: {
      'p_tenant_id': tenantId,
    }) as List<dynamic>;
    return res
        .map((e) => CobradorAdmin.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> setCobradorActivo({
    required String cobradorId,
    required bool activo,
  }) async {
    await _client.rpc('set_cobrador_activo', params: {
      'p_cobrador_id': cobradorId,
      'p_activo': activo,
    });
  }

  Future<void> setCobradorRol({
    required String cobradorId,
    required String nuevoRol,
  }) async {
    await _client.rpc('set_cobrador_rol', params: {
      'p_cobrador_id': cobradorId,
      'p_nuevo_rol': nuevoRol,
    });
  }

  /// Llama a la Edge Function `forzar-password-cobrador` con service_role
  /// del lado server. Sólo super_admin lo puede usar; los guards los hace
  /// la Edge Function.
  Future<void> forzarPasswordCobrador({
    required String cobradorId,
    required String nuevaPassword,
  }) async {
    await _invokeFn('forzar-password-cobrador', body: {
      'cobrador_id': cobradorId,
      'nueva_password': nuevaPassword,
    });
  }

  /// Llama a la Edge Function `reenviar-invitacion`. Borra el user
  /// pending y lo re-crea con la misma metadata.
  ///
  /// Si `enviarEmail` es true (default): Supabase manda un email nuevo
  /// con magic-link. Si es false: se genera password aleatoria server
  /// side y se devuelve en `nuevaPassword` para que el caller la
  /// muestre y el super_admin la comparta por otro canal (workaround
  /// SMTP en sandbox). En ambos modos devolvemos también el email y
  /// el nuevo user_id.
  Future<({String newUserId, String email, String? nuevaPassword})>
      reenviarInvitacion({
    required String cobradorId,
    String? redirectTo,
    bool enviarEmail = true,
  }) async {
    final data = await _invokeFn('reenviar-invitacion', body: {
      'cobrador_id': cobradorId,
      if (redirectTo != null) 'redirect_to': redirectTo,
      // Explícito siempre para que un cambio futuro del default en el
      // server no rompa este caller silenciosamente.
      'enviar_email': enviarEmail,
    });
    return (
      newUserId: data['new_user_id'] as String,
      email: data['email'] as String,
      nuevaPassword: data['nueva_password'] as String?,
    );
  }

  /// Llama a la Edge Function `cambiar-email-cobrador`. Sólo super_admin.
  Future<void> cambiarEmailCobrador({
    required String cobradorId,
    required String nuevoEmail,
  }) async {
    await _invokeFn('cambiar-email-cobrador', body: {
      'cobrador_id': cobradorId,
      'nuevo_email': nuevoEmail,
    });
  }

  /// Llama a la Edge Function `eliminar-cobrador`. Sólo super_admin.
  /// Bloquea si el usuario tiene historial operativo — sugerirá desactivar.
  Future<void> eliminarCobrador({required String cobradorId}) async {
    await _invokeFn('eliminar-cobrador', body: {
      'cobrador_id': cobradorId,
    });
  }

  /// Registra en audit_log un intento de reset password vía email. El
  /// reset en sí lo dispara el cliente con auth.resetPasswordForEmail
  /// (API pública); esta RPC sólo escribe el audit entry. Si falla, no
  /// bloqueamos el flow — el email ya está en tránsito.
  Future<void> auditResetPassword(String cobradorId) async {
    await _client.rpc('audit_reset_password', params: {
      'p_cobrador_id': cobradorId,
    });
  }

  Future<CobradorStats?> getCobradorStats(String cobradorId) async {
    final res = await _client.rpc('get_cobrador_stats', params: {
      'p_cobrador_id': cobradorId,
    }) as List<dynamic>;
    if (res.isEmpty) return null;
    return CobradorStats.fromMap(
      Map<String, dynamic>.from(res.first as Map),
    );
  }

  Future<List<AuditEntry>> listAuditCobrador({
    required String cobradorId,
    int limit = 50,
  }) async {
    final res = await _client.rpc('list_audit_cobrador', params: {
      'p_cobrador_id': cobradorId,
      'p_limit': limit,
    }) as List<dynamic>;
    return res
        .map((e) => AuditEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}

final superAdminRepoProvider = Provider<SuperAdminRepo>(
  (_) => SuperAdminRepo(Supabase.instance.client),
);

/// Catálogo de módulos (estable durante la sesión).
final modulosProvider = FutureProvider<List<Modulo>>((ref) {
  return ref.read(superAdminRepoProvider).listModulos();
});

/// Lista de tenants. Se invalida al cambiar un módulo (ver tenant detail).
final tenantsAdminProvider = FutureProvider<List<TenantAdmin>>((ref) {
  return ref.read(superAdminRepoProvider).listTenants();
});

/// Lista de miembros (cobradores) de un tenant específico. Family por
/// tenant_id para que cada pantalla de detalle cachee independientemente.
final cobradoresTenantProvider =
    FutureProvider.family<List<CobradorAdmin>, String>(
  (ref, tenantId) =>
      ref.read(superAdminRepoProvider).listCobradoresTenant(tenantId),
);

/// Stats agregadas de un miembro para la pantalla de detalle.
final cobradorStatsProvider =
    FutureProvider.family<CobradorStats?, String>(
  (ref, cobradorId) =>
      ref.read(superAdminRepoProvider).getCobradorStats(cobradorId),
);

/// Timeline de audit_log del miembro (últimos 50 eventos).
final auditCobradorProvider =
    FutureProvider.family<List<AuditEntry>, String>(
  (ref, cobradorId) => ref
      .read(superAdminRepoProvider)
      .listAuditCobrador(cobradorId: cobradorId),
);
