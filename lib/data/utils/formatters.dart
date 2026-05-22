import 'package:intl/intl.dart';

class Fmt {
  static final _nio = NumberFormat.currency(
    locale: 'es_NI',
    symbol: 'C\$',
    decimalDigits: 2,
  );

  static final _usd = NumberFormat.currency(
    locale: 'es_NI',
    symbol: 'US\$',
    decimalDigits: 2,
  );

  static final _fechaCorta = DateFormat('dd/MM/yyyy', 'es_NI');
  static final _fechaLarga = DateFormat("d 'de' MMMM 'de' y", 'es_NI');
  static final _mes = DateFormat('MMMM y', 'es_NI');
  static final _diaSemana = DateFormat('EEEE', 'es_NI');
  static final _hora = DateFormat('HH:mm', 'es_NI');

  static String cordobas(num v) => _nio.format(v);
  static String dolares(num v) => _usd.format(v);
  static String monto(num v, String moneda) =>
      moneda == 'USD' ? dolares(v) : cordobas(v);

  static String fechaCorta(DateTime d) => _fechaCorta.format(d);
  static String fechaLarga(DateTime d) => _fechaLarga.format(d);
  static String mes(DateTime d) => _mes.format(d);
  static String diaSemana(DateTime d) =>
      _diaSemana.format(d)[0].toUpperCase() + _diaSemana.format(d).substring(1);
  static String hora(DateTime d) => _hora.format(d);

  static String fechaRelativa(DateTime d, [DateTime? hoy]) {
    final ref = hoy ?? DateTime.now();
    final base = DateTime(ref.year, ref.month, ref.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = target.difference(base).inDays;
    if (diff == 0) return 'Hoy';
    if (diff == 1) return 'Mañana';
    if (diff == -1) return 'Ayer';
    if (diff > 0 && diff < 7) return 'En $diff días';
    if (diff < 0 && diff > -7) return 'Hace ${-diff} días';
    return fechaCorta(d);
  }

  /// Período que se muestra en el recibo. Regla del 15 sobre el DÍA DE
  /// PAGO DEL CLIENTE (no la fecha de emisión variable):
  ///   - dia_pago ≤ 14: el recibo cubre el mismo mes que `periodo`.
  ///   - dia_pago ≥ 15: el recibo cubre el MES SIGUIENTE a `periodo`.
  ///
  /// `periodo` viene de `cuotas.periodo` — el mes calendario de la cuota.
  static String periodoRecibo(int diaPago, DateTime periodo) {
    final mesObjetivo = diaPago >= 15
        ? DateTime(periodo.year, periodo.month + 1, 1)
        : DateTime(periodo.year, periodo.month, 1);
    return mes(mesObjetivo);
  }
}
