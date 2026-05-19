import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/cobrador_admin.dart';
import '../models/modulo.dart';
import '../models/tenant_admin.dart';

/// Repo del panel /super/*. Habla con Supabase por RPC — no toca el SQLite
/// local. Las tablas modulos / tenant_modulos no se sincronizan al cliente.
class SuperAdminRepo {
  const SuperAdminRepo(this._client);

  final SupabaseClient _client;

  Future<List<Modulo>> listModulos() async {
    final res = await _client.rpc('list_modulos') as List<dynamic>;
    return res
        .map((e) => Modulo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
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
    final res = await _client.functions.invoke(
      'forzar-password-cobrador',
      body: {
        'cobrador_id': cobradorId,
        'nueva_password': nuevaPassword,
      },
    );
    final data = res.data as Map<String, dynamic>?;
    if (data == null || data['ok'] != true) {
      throw Exception(
        (data?['error'] as String?) ?? 'Error desconocido',
      );
    }
  }

  /// Llama a la Edge Function `reenviar-invitacion`. La función borra
  /// el usuario pending y crea uno nuevo con la misma metadata, así
  /// el email de invitación llega fresco.
  Future<void> reenviarInvitacion({
    required String cobradorId,
    String? redirectTo,
  }) async {
    final res = await _client.functions.invoke(
      'reenviar-invitacion',
      body: {
        'cobrador_id': cobradorId,
        if (redirectTo != null) 'redirect_to': redirectTo,
      },
    );
    final data = res.data as Map<String, dynamic>?;
    if (data == null || data['ok'] != true) {
      throw Exception(
        (data?['error'] as String?) ?? 'Error desconocido',
      );
    }
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
