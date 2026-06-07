import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../powersync/db.dart' as ps;

/// Códigos de módulos opcionales HABILITADOS para el tenant actual (o el
/// impersonado por el super_admin). Read-only: la fuente de verdad es
/// `tenant_modulos`, que togglea el super_admin vía RPC (`set_tenant_modulo`).
/// Se sincroniza por PowerSync (sync rules). Gatea la UI de módulos opcionales
/// como Inventario: si el código no está acá, el menú/ruta no aparece.
///
/// `habilitado` se guarda como entero 0/1 en SQLite (PowerSync no tiene bool).
final modulosHabilitadosProvider = StreamProvider<Set<String>>((ref) {
  return ps.db
      .watch('SELECT modulo_codigo FROM tenant_modulos WHERE habilitado = 1')
      .map((rows) => rows.map((r) => r['modulo_codigo'] as String).toSet());
});
