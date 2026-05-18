/// Representa al usuario logueado (super_admin / admin / admin_cobranza / cobrador).
/// Se sincroniza desde la tabla `cobradores`.
class Cobrador {
  const Cobrador({
    required this.id,
    required this.tenantId,
    required this.nombre,
    this.telefono,
    required this.rol,
    this.prefijoRecibo,
    required this.activo,
  });

  final String id;
  final String tenantId;
  final String nombre;
  final String? telefono;
  final String rol;
  final String? prefijoRecibo;
  final bool activo;

  bool get esSuperAdmin => rol == 'super_admin';
  bool get esAdmin => rol == 'admin';
  bool get esAdminCobranza => rol == 'admin_cobranza';
  bool get esCobrador => rol == 'cobrador';

  /// True para roles con acceso a opciones restringidas del panel admin
  /// (cobradores, settings, geografía, planes, auditoría).
  /// super_admin hereda todos los permisos de admin.
  bool get tieneAccesoAdmin => esAdmin || esSuperAdmin;

  factory Cobrador.fromRow(Map<String, dynamic> row) => Cobrador(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        nombre: row['nombre'] as String,
        telefono: row['telefono'] as String?,
        rol: row['rol'] as String,
        prefijoRecibo: row['prefijo_recibo'] as String?,
        activo: (row['activo'] as int? ?? 1) == 1,
      );
}
