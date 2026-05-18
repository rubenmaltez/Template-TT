/// Tenant tal como lo ve el super_admin. Llega desde la RPC
/// `list_tenants_admin` con métricas pre-calculadas.
class TenantAdmin {
  const TenantAdmin({
    required this.id,
    required this.nombre,
    required this.createdAt,
    required this.cobradoresCount,
    required this.modulosHabilitados,
  });

  final String id;
  final String nombre;
  final DateTime createdAt;
  final int cobradoresCount;
  final List<String> modulosHabilitados;

  bool tieneModulo(String codigo) => modulosHabilitados.contains(codigo);

  factory TenantAdmin.fromMap(Map<String, dynamic> m) => TenantAdmin(
        id: m['id'] as String,
        nombre: m['nombre'] as String,
        createdAt: DateTime.parse(m['created_at'] as String),
        cobradoresCount: (m['cobradores_count'] as num).toInt(),
        modulosHabilitados:
            (m['modulos_habilitados'] as List).cast<String>(),
      );
}
