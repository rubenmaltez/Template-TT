/// Prorrateo "por días" para el cambio de fecha de pago (feature C) y la
/// suspensión temporal (feature A).
///
/// **Convención de negocio (decisión de Rubén, 2026-06-14):** el precio de un
/// día de servicio = `precio_mensual / días reales del mes` de esa fecha. Si un
/// rango cruza dos meses, cada día se valúa con los días de SU propio mes
/// (un día de junio = precio/30, uno de julio = precio/31).
///
/// **Servicio vs cobro:** el servicio corre TODOS los días (incluidos domingos),
/// así que el prorrateo usa días calendario crudos. El ajuste domingo→lunes del
/// server (`calcular_fecha_pago`) es SOLO para la fecha de COBRO de las cuotas,
/// no para el conteo de días de servicio.
library;

/// Días reales del mes de [year]/[month] (1-12). 28/29/30/31.
int diasDelMes(int year, int month) => DateTime(year, month + 1, 0).day;

/// Precio de un día de servicio en el mes de [fecha].
double precioPorDia(DateTime fecha, double precioMensual) =>
    precioMensual / diasDelMes(fecha.year, fecha.month);

/// Trunca a fecha-sólo (sin hora) para que las diferencias de días sean exactas.
DateTime _soloFecha(DateTime d) => DateTime(d.year, d.month, d.day);

/// Cantidad de días del puente entre [pagadoHasta] (último día ya cubierto,
/// EXCLUSIVO) y [anclaServicio] (INCLUSIVO). Es simplemente la diferencia de
/// fechas en días. Ej: 15-jun → 10-jul = 25.
int diasPuente(DateTime pagadoHasta, DateTime anclaServicio) =>
    _soloFecha(anclaServicio).difference(_soloFecha(pagadoHasta)).inDays;

/// Monto del puente: cada día desde `pagadoHasta + 1` hasta `anclaServicio`
/// (inclusive) valuado con el precio diario de su mes. Redondeado a centavos.
/// Devuelve 0 si el ancla no es posterior a lo pagado.
double montoPuente(
    DateTime pagadoHasta, DateTime anclaServicio, double precioMensual) {
  var monto = 0.0;
  var d = _soloFecha(pagadoHasta).add(const Duration(days: 1));
  final fin = _soloFecha(anclaServicio);
  while (!d.isAfter(fin)) {
    monto += precioPorDia(d, precioMensual);
    d = d.add(const Duration(days: 1));
  }
  return (monto * 100).round() / 100;
}

/// Día [diaNuevo] (1-31) clampeado al último día real del mes [year]/[month].
/// Espeja el clamp de `calcular_fecha_pago` (ej. 31 en febrero → 28/29).
int diaClampMes(int year, int month, int diaNuevo) {
  final ult = diasDelMes(year, month);
  return diaNuevo < ult ? diaNuevo : ult;
}

/// **Ancla de servicio del nuevo día de pago**: la primera fecha cuyo día sea
/// [diaNuevo] (clampeado a fin de mes) ESTRICTAMENTE posterior a [pagadoHasta].
/// Sin ajuste domingo→lunes (eso es de la fecha de cobro, no del servicio).
///
/// Ejemplos (pagadoHasta = 15-jun): día 30 → 30-jun · día 14 → 14-jul ·
/// día 10 → 10-jul · día 16 → 16-jun.
DateTime anclaServicio(DateTime pagadoHasta, int diaNuevo) {
  final base = _soloFecha(pagadoHasta);
  var y = base.year;
  var m = base.month;
  var cand = DateTime(y, m, diaClampMes(y, m, diaNuevo));
  if (!cand.isAfter(base)) {
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
    cand = DateTime(y, m, diaClampMes(y, m, diaNuevo));
  }
  return cand;
}

/// Resultado de simular un cambio de fecha de pago.
class PuenteCambioFecha {
  const PuenteCambioFecha({
    required this.anclaServicio,
    required this.diasPuente,
    required this.montoPuente,
  });

  /// Primera fecha de servicio con el día nuevo, posterior a lo pagado.
  final DateTime anclaServicio;

  /// Días de servicio del puente a cobrar.
  final int diasPuente;

  /// Monto a cobrar por el puente (córdobas, 2 decimales).
  final double montoPuente;
}

/// Calcula el puente completo de un cambio de fecha de pago al [diaNuevo],
/// dado lo que el cliente ya pagó ([pagadoHasta]) y el [precioMensual].
PuenteCambioFecha calcularPuenteCambioFecha({
  required DateTime pagadoHasta,
  required int diaNuevo,
  required double precioMensual,
}) {
  final ancla = anclaServicio(pagadoHasta, diaNuevo);
  return PuenteCambioFecha(
    anclaServicio: ancla,
    diasPuente: diasPuente(pagadoHasta, ancla),
    montoPuente: montoPuente(pagadoHasta, ancla, precioMensual),
  );
}
