/// Lógica pura del estado de una cuota en función del total pagado y
/// cargos extra. **Espeja exactamente** la función SQL
/// `recalcular_cuota_desde_pagos` (migración 0012/0018/0075) — cualquier
/// cambio acá debe replicarse en el server y viceversa.
///
/// **Por qué extraída a función pura**: facilita testing (sin
/// dependencias de Provider / BD), y permite que múltiples flows del
/// cliente (cobro inmediato, undo de pago, edición de cargo extra)
/// usen la misma fuente de verdad sin duplicar la lógica.
///
/// **Regla**:
///   - Si la cuota está `anulada`, queda `anulada` (no cambia).
///   - `totalReal = max(0, montoCuota + deltaCargosExtra)`.
///     `deltaCargosExtra` puede ser negativo (descuento) — si bajaría
///     el total bajo 0, lo clampeamos a 0 (cuota efectivamente gratis).
///   - `pagadoNuevo <= 0` → `pendiente`.
///   - `pagadoNuevo >= totalReal` → `pagada`.
///   - Cualquier otro caso → `parcial`.
String calcularEstadoCuota({
  required String estadoActual,
  required double montoCuota,
  required double pagadoNuevo,
  required double deltaCargosExtra,
}) {
  if (estadoActual == 'anulada') return 'anulada';
  final totalReal =
      (montoCuota + deltaCargosExtra).clamp(0.0, double.infinity).toDouble();
  if (pagadoNuevo <= 0) return 'pendiente';
  if (pagadoNuevo >= totalReal) return 'pagada';
  return 'parcial';
}
