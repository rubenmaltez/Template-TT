/// Cálculo contable del cobro — lógica pura, testeable sin DB.
///
/// Centraliza la matemática del vuelto que históricamente tuvo un bug
/// crítico (se guardaba lo entregado como aplicado, inflando el recaudado).
///
/// Invariantes de dinero (ver CLAUDE.md → "Invariantes de dinero"):
///   - aplicado = min(entregado, saldo)  → lo que entra a la caja del ISP
///   - vuelto   = entregado - aplicado   → devuelto al cliente, SIEMPRE en NIO
///   - entregado = aplicado + vuelto
///
/// Todos los montos acá son en CÓRDOBAS (NIO). La conversión USD→NIO se hace
/// ANTES de llamar a estas funciones (entregadoCordobas = entregadoUsd * tasa).
class CobroCalculo {
  const CobroCalculo._();

  /// Resultado del cálculo de un cobro contra un saldo.
  ///
  /// [entregadoCordobas]: lo que el cliente puso en mano, ya convertido a NIO.
  /// [saldoCordobas]: el saldo pendiente de la cuota (o suma de cuotas).
  ///
  /// Trunca el aplicado al saldo: nunca se aplica de más a la cuota. El exceso
  /// es vuelto. Negativos imposibles (clamp defensivo).
  static CobroDistribucion calcular({
    required double entregadoCordobas,
    required double saldoCordobas,
  }) {
    final entregado = entregadoCordobas < 0 ? 0.0 : entregadoCordobas;
    final saldo = saldoCordobas < 0 ? 0.0 : saldoCordobas;
    final aplicado = entregado > saldo ? saldo : entregado;
    final vuelto = entregado - aplicado;
    return CobroDistribucion(
      aplicadoCordobas: aplicado,
      vueltoCordobas: vuelto,
    );
  }

  /// Convierte un monto en la moneda elegida a córdobas.
  /// NIO: la tasa es 1. USD: multiplica por la tasa de conversión.
  static double aCordobas(double monto, double tasa) => monto * tasa;
}

/// Distribución de un cobro: cuánto se aplicó a la cuota y cuánto fue vuelto.
class CobroDistribucion {
  const CobroDistribucion({
    required this.aplicadoCordobas,
    required this.vueltoCordobas,
  });

  /// Lo que entra a la caja del ISP (se guarda en `pagos.monto_cordobas`).
  final double aplicadoCordobas;

  /// Lo devuelto al cliente, siempre en NIO (`pagos.vuelto_cordobas`).
  final double vueltoCordobas;

  /// Lo entregado por el cliente = aplicado + vuelto.
  double get entregadoCordobas => aplicadoCordobas + vueltoCordobas;

  /// True si hubo vuelto (con tolerancia de redondeo).
  bool get tieneVuelto => vueltoCordobas > 0.01;
}
