enum CuotaEstado {
  pendiente,
  parcial,
  pagada,
  anulada;

  static CuotaEstado fromString(String s) => switch (s) {
        'pendiente' => CuotaEstado.pendiente,
        'parcial' => CuotaEstado.parcial,
        'pagada' => CuotaEstado.pagada,
        'anulada' => CuotaEstado.anulada,
        _ => CuotaEstado.pendiente,
      };

  String get label => switch (this) {
        CuotaEstado.pendiente => 'Pendiente',
        CuotaEstado.parcial => 'Parcial',
        CuotaEstado.pagada => 'Pagada',
        CuotaEstado.anulada => 'Anulada',
      };
}

/// Estado VISUAL derivado: vencida/en_gracia se computa con la fecha actual
/// y los días de gracia configurados en settings — no se almacena en BD.
enum CuotaEstadoVisual {
  pendiente,
  parcial,
  enGracia,
  vencida,
  pagada,
  anulada;

  String get label => switch (this) {
        CuotaEstadoVisual.pendiente => 'Al día',
        CuotaEstadoVisual.parcial => 'Pago parcial',
        CuotaEstadoVisual.enGracia => 'En gracia',
        CuotaEstadoVisual.vencida => 'Vencida',
        CuotaEstadoVisual.pagada => 'Pagada',
        CuotaEstadoVisual.anulada => 'Anulada',
      };

  bool get esCobrable =>
      this == CuotaEstadoVisual.pendiente ||
      this == CuotaEstadoVisual.parcial ||
      this == CuotaEstadoVisual.enGracia ||
      this == CuotaEstadoVisual.vencida;
}

class Cuota {
  const Cuota({
    required this.id,
    required this.tenantId,
    this.contratoId,
    required this.clienteId,
    this.cobradorId,
    required this.periodo,
    required this.fechaVencimiento,
    required this.monto,
    required this.montoPagado,
    required this.cargosNeto,
    required this.estado,
    this.descripcion,
  });

  final String id;
  final String tenantId;
  /// Null para cuotas manuales (no ligadas a contrato).
  final String? contratoId;
  final String clienteId;
  final String? cobradorId;
  final DateTime periodo;
  final DateTime fechaVencimiento;
  final double monto;
  final double montoPagado;
  /// Suma de cargos extra netos (reconexión + otro - descuentos).
  /// Mantenido por trigger en server (migración 0023).
  final double cargosNeto;
  final CuotaEstado estado;
  /// Descripción libre para cuotas manuales (ej: "Cargo por reconexión").
  final String? descripcion;

  /// Indica si la cuota es manual (no generada desde contrato).
  bool get esManual => contratoId == null;

  /// Total real a cobrar (monto + cargos netos).
  double get totalACobrar => (monto + cargosNeto).clamp(0, double.infinity);

  /// Saldo pendiente considerando cargos extra.
  double get saldo => (totalACobrar - montoPagado).clamp(0, double.infinity);

  CuotaEstadoVisual estadoVisual(int diasGracia, [DateTime? hoy]) {
    if (estado == CuotaEstado.pagada) return CuotaEstadoVisual.pagada;
    if (estado == CuotaEstado.anulada) return CuotaEstadoVisual.anulada;

    final ref = hoy ?? DateTime.now();
    final vence = DateTime(
        fechaVencimiento.year, fechaVencimiento.month, fechaVencimiento.day);
    final hoyD = DateTime(ref.year, ref.month, ref.day);
    final diff = hoyD.difference(vence).inDays;

    if (diff <= 0) {
      return estado == CuotaEstado.parcial
          ? CuotaEstadoVisual.parcial
          : CuotaEstadoVisual.pendiente;
    }
    if (diff <= diasGracia) return CuotaEstadoVisual.enGracia;
    return CuotaEstadoVisual.vencida;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cuota &&
          other.id == id &&
          other.tenantId == tenantId &&
          other.contratoId == contratoId &&
          other.clienteId == clienteId &&
          other.cobradorId == cobradorId &&
          other.periodo == periodo &&
          other.fechaVencimiento == fechaVencimiento &&
          other.monto == monto &&
          other.montoPagado == montoPagado &&
          other.cargosNeto == cargosNeto &&
          other.estado == estado &&
          other.descripcion == descripcion;

  @override
  int get hashCode => Object.hash(
        id,
        tenantId,
        contratoId,
        clienteId,
        cobradorId,
        periodo,
        fechaVencimiento,
        monto,
        montoPagado,
        cargosNeto,
        estado,
        descripcion,
      );

  factory Cuota.fromRow(Map<String, dynamic> row) => Cuota(
        id: row['id'] as String,
        tenantId: row['tenant_id'] as String,
        contratoId: row['contrato_id'] as String?,
        clienteId: row['cliente_id'] as String,
        cobradorId: row['cobrador_id'] as String?,
        periodo: DateTime.parse(row['periodo'] as String),
        fechaVencimiento: DateTime.parse(row['fecha_vencimiento'] as String),
        monto: (row['monto'] as num).toDouble(),
        montoPagado: (row['monto_pagado'] as num? ?? 0).toDouble(),
        cargosNeto: (row['cargos_neto'] as num? ?? 0).toDouble(),
        estado: CuotaEstado.fromString(row['estado'] as String),
        descripcion: row['descripcion'] as String?,
      );
}
