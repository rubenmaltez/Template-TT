class Cliente {
  const Cliente({
    required this.id,
    required this.tenantId,
    this.cobradorId,
    this.comunidadId,
    required this.nombre,
    this.cedula,
    this.telefono,
    this.direccion,
    this.direccionReferencia,
    this.latitud,
    this.longitud,
    this.fotoPath,
    required this.activo,
  });

  final String id;
  final String tenantId;
  final String? cobradorId;
  final String? comunidadId;
  final String nombre;
  final String? cedula;
  final String? telefono;
  final String? direccion;
  final String? direccionReferencia;
  final double? latitud;
  final double? longitud;
  final String? fotoPath;
  final bool activo;

  bool get tieneUbicacion => latitud != null && longitud != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cliente &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.cobradorId == cobradorId &&
          other.comunidadId == comunidadId &&
          other.nombre == nombre &&
          other.cedula == cedula &&
          other.telefono == telefono &&
          other.direccion == direccion &&
          other.direccionReferencia == direccionReferencia &&
          other.latitud == latitud &&
          other.longitud == longitud &&
          other.fotoPath == fotoPath &&
          other.activo == activo;

  @override
  int get hashCode => Object.hash(
        id,
        tenantId,
        cobradorId,
        comunidadId,
        nombre,
        cedula,
        telefono,
        direccion,
        direccionReferencia,
        latitud,
        longitud,
        fotoPath,
        activo,
      );

  factory Cliente.fromRow(Map<String, dynamic> row) => Cliente(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        cobradorId: row['cobrador_id'] as String?,
        comunidadId: row['comunidad_id'] as String?,
        nombre: row['nombre'] as String,
        cedula: row['cedula'] as String?,
        telefono: row['telefono'] as String?,
        direccion: row['direccion'] as String?,
        direccionReferencia: row['direccion_referencia'] as String?,
        latitud: (row['latitud'] as num?)?.toDouble(),
        longitud: (row['longitud'] as num?)?.toDouble(),
        fotoPath: row['foto_path'] as String?,
        activo: (row['activo'] as int? ?? 1) == 1,
      );
}
