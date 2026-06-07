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
  // Roles de Fase 3 (tickets). `tecnico` es móvil-first (shell propio);
  // `admin_tickets` es un admin acotado a tickets/inventario.
  bool get esTecnico => rol == 'tecnico';
  bool get esAdminTickets => rol == 'admin_tickets';

  /// True para roles con acceso a opciones restringidas del panel admin
  /// (cobradores, settings, geografía, planes, auditoría).
  /// super_admin hereda todos los permisos de admin.
  bool get tieneAccesoAdmin => esAdmin || esSuperAdmin;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cobrador &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.nombre == nombre &&
          other.telefono == telefono &&
          other.rol == rol &&
          other.prefijoRecibo == prefijoRecibo &&
          other.activo == activo;

  @override
  int get hashCode => Object.hash(
        id,
        tenantId,
        nombre,
        telefono,
        rol,
        prefijoRecibo,
        activo,
      );

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
