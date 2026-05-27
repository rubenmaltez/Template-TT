class Contrato {
  const Contrato({
    required this.id,
    required this.tenantId,
    required this.clienteId,
    this.cobradorId,
    required this.planId,
    required this.diaPago,
    required this.fechaInicio,
    this.fechaFin,
    required this.estado,
  });

  final String id;
  final String tenantId;
  final String clienteId;
  final String? cobradorId;
  final String planId;
  final int diaPago;
  final DateTime fechaInicio;
  final DateTime? fechaFin;
  final String estado;

  bool get activo => estado == 'activo';

  /// Duración legible: '1 año', '2 años', 'Indefinido' o 'N meses'.
  String get duracionLabel {
    if (fechaFin == null) return 'Indefinido';
    final meses = _mesesEntre(fechaInicio, fechaFin!);
    if (meses == 12) return '1 año';
    if (meses == 24) return '2 años';
    return '$meses meses';
  }

  bool get esIndefinido => fechaFin == null;

  factory Contrato.fromRow(Map<String, dynamic> row) => Contrato(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        clienteId: row['cliente_id'] as String,
        cobradorId: row['cobrador_id'] as String?,
        planId: row['plan_id'] as String,
        diaPago: row['dia_pago'] as int,
        fechaInicio: DateTime.parse(row['fecha_inicio'] as String),
        fechaFin: row['fecha_fin'] != null
            ? DateTime.parse(row['fecha_fin'] as String)
            : null,
        estado: row['estado'] as String? ?? 'activo',
      );
}

int _mesesEntre(DateTime a, DateTime b) {
  return (b.year - a.year) * 12 + (b.month - a.month);
}
