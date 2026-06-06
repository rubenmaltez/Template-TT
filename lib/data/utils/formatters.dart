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
  static final _fechaHora = DateFormat('dd/MM/yyyy HH:mm', 'es_NI');

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

  /// Formatea un timestamp `fecha_pago` (string crudo de SQLite) a
  /// dd/MM/yyyy HH:mm. `fecha_pago` se guarda como hora LOCAL de Nicaragua
  /// (wall-clock, sin `Z`), así que se formatea DIRECTO: `DateTime.parse` toma
  /// los campos tal cual del string en cualquier dispositivo, sin shift de TZ.
  /// Coincide con cómo el recibo muestra la misma fecha y con cómo los reportes
  /// la agrupan (`date(fecha_pago)` crudo). Si no parsea, devuelve el raw.
  static String fechaHoraNi(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return _fechaHora.format(dt);
  }

  /// Igual que [fechaHoraNi] pero solo la fecha (dd/MM/yyyy).
  static String fechaNi(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return _fechaCorta.format(dt);
  }

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

  /// Mes "simbólico" que representa una cuota — el que sale en el recibo.
  ///
  /// Facturación VENCIDA: la cuota cubre el período de servicio que TERMINA
  /// en su vencimiento y arranca el mismo día del mes anterior. El mes
  /// mostrado es el que tiene MÁS días dentro de ese período (el que el
  /// cliente más usó). Empate exacto → gana el mes del vencimiento.
  ///
  /// [periodo] = primer día del MES DE VENCIMIENTO de la cuota
  /// (`cuotas.periodo`). [diaPago] = día de cobro del contrato.
  ///
  /// Ejemplos (validados con Rubén):
  ///   - venc 14/jun (periodo=jun, día 14) → mayo (18 días vs 13).
  ///   - venc 25/may (periodo=may, día 25) → mayo (24 vs 6).
  ///   - venc 5/may  (periodo=may, día 5)  → abril (26 vs 4).
  ///   - venc 28/feb (periodo=feb, día 31) → febrero (27 vs 1).
  static DateTime mesServicio(int diaPago, DateTime periodo) {
    final mesVenc = DateTime(periodo.year, periodo.month, 1);
    final mesAnterior = DateTime(periodo.year, periodo.month - 1, 1);
    // Último día real de cada mes (DateTime(y, m+1, 0) = último de m).
    final ultDiaVenc = DateTime(mesVenc.year, mesVenc.month + 1, 0).day;
    final ultDiaAnt = DateTime(mesAnterior.year, mesAnterior.month + 1, 0).day;
    // Día clampeado al último día real (ej. 31 en febrero → 28).
    final diaVenc = diaPago < ultDiaVenc ? diaPago : ultDiaVenc;
    final diaInicio = diaPago < ultDiaAnt ? diaPago : ultDiaAnt;
    // Período [diaInicio del mes anterior, diaVenc del mes de vencimiento).
    final diasMesAnterior = ultDiaAnt - diaInicio + 1;
    final diasMesVenc = diaVenc - 1;
    return diasMesAnterior > diasMesVenc ? mesAnterior : mesVenc;
  }

  /// Período que se muestra en el recibo (sin capitalizar). Deriva el mes
  /// de servicio de `mesServicio`. Ver esa función para la regla.
  static String periodoRecibo(int diaPago, DateTime periodo) =>
      mes(mesServicio(diaPago, periodo));

  /// Label capitalizado del mes de servicio de una cuota, para listas y
  /// detalles. Si [diaPago] es null (cuota manual sin contrato) usa el mes
  /// del `periodo` tal cual — las cuotas manuales no tienen período de
  /// servicio derivado.
  static String mesServicioLabel(DateTime periodo, int? diaPago) {
    final m = diaPago == null
        ? DateTime(periodo.year, periodo.month, 1)
        : mesServicio(diaPago, periodo);
    final s = mes(m);
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Rango de fechas del período de servicio que cubre una cuota (modelo de
  /// facturación VENCIDA): del día de pago del mes anterior al día de
  /// vencimiento. Ambos extremos clampeados al último día real de su mes
  /// (ej. día 31 en un mes de 30 → 30). Devuelve "DD/MM/AAAA a DD/MM/AAAA".
  ///
  /// [fechaVencimiento] = fin del período (la fecha de cobro de la cuota, ya
  /// clampeada por el server). [diaPago] = día de cobro del contrato; null en
  /// cuotas manuales (sin contrato) → devuelve null porque no hay período de
  /// servicio derivado.
  static String? periodoServicioRango(int? diaPago, DateTime fechaVencimiento) {
    if (diaPago == null) return null;
    final fin = fechaVencimiento;
    // Primer día del mes anterior al vencimiento (month-1 en enero → dic del
    // año previo, lo normaliza DateTime).
    final mesAnt = DateTime(fin.year, fin.month - 1, 1);
    // Último día real del mes anterior (DateTime(y, m+1, 0) = último de m).
    final ultDiaAnt = DateTime(mesAnt.year, mesAnt.month + 1, 0).day;
    final diaInicio = diaPago < ultDiaAnt ? diaPago : ultDiaAnt;
    final inicio = DateTime(mesAnt.year, mesAnt.month, diaInicio);
    return '${fechaCorta(inicio)} a ${fechaCorta(fin)}';
  }
}
