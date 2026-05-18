import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
