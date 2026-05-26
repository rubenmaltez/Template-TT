/// Una entrada del audit_log enriquecida con datos del autor del cambio
/// (email + nombre). Llega desde la RPC `list_audit_cobrador`.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.tabla,
    this.registroId,
    this.campo,
    this.accion = 'update',
    this.valorAnterior,
    this.valorNuevo,
    this.userId,
    this.userRol,
    this.userEmail,
    this.userNombre,
    required this.createdAt,
  });

  final String id;
  final String tabla;
  final String? registroId;
  final String? campo;
  final String accion;
  /// jsonb del valor anterior — puede ser null, primitivo, o object.
  final dynamic valorAnterior;
  /// jsonb del valor nuevo — puede ser null, primitivo, o object.
  final dynamic valorNuevo;
  final String? userId;
  final String? userRol;
  final String? userEmail;
  final String? userNombre;
  final DateTime createdAt;

  /// Mejor etiqueta disponible para el autor: nombre > email > id > '—'.
  String get autorDisplay =>
      userNombre ?? userEmail ?? (userId != null ? 'user $userId' : '—');

  // Audit log es append-only — dos rows con mismo id son idénticas.
  // Comparar por id es semánticamente correcto y evita el complejo
  // deep-equality de los jsonb dynamic (valorAnterior/valorNuevo).
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AuditEntry && other.id == id;

  @override
  int get hashCode => id.hashCode;

  factory AuditEntry.fromMap(Map<String, dynamic> m) => AuditEntry(
        id: m['id'] as String,
        tabla: m['tabla'] as String,
        registroId: m['registro_id'] as String?,
        campo: m['campo'] as String?,
        accion: m['accion'] as String? ?? 'update',
        valorAnterior: m['valor_anterior'],
        valorNuevo: m['valor_nuevo'],
        userId: m['user_id'] as String?,
        userRol: m['user_rol'] as String?,
        userEmail: m['user_email'] as String?,
        userNombre: m['user_nombre'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}
