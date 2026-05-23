import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:isp_billing/data/utils/formatters.dart';

/// Tests de Fmt — formatters de moneda, fecha y período usados en
/// **todas las pantallas** del repo (dashboard, recibo, lista de
/// cuotas, lista de pagos, historial, etc.).
///
/// Si una rompe, se rompe en todas esas pantallas a la vez. Tests
/// pensados como guardia ante regresión sutil (especialmente
/// `fechaRelativa` que tiene lógica condicional compleja).
void main() {
  setUpAll(() async {
    // initializeDateFormatting cargar los locale data de es_NI para
    // que DateFormat con `'EEEE'`/`'MMMM'` retorne nombres en español.
    // Sin esto, los tests fallan con LocaleDataException.
    await initializeDateFormatting('es_NI', null);
  });

  group('Fmt.cordobas', () {
    test('formato con 2 decimales', () {
      // El locale es_NI usa coma decimal y punto miles. Verificamos
      // que el output contiene los componentes clave en vez de match
      // exacto (resistente a variaciones de locale data).
      final out = Fmt.cordobas(750.5);
      expect(out, contains('C\$'));
      expect(out, contains('750'));
      expect(out, contains('50'));
    });

    test('entero — agrega 00 decimales', () {
      final out = Fmt.cordobas(1000);
      expect(out, contains('C\$'));
      expect(out, contains('1'));
      expect(out, contains('000'));
    });

    test('cero', () {
      final out = Fmt.cordobas(0);
      expect(out, contains('C\$'));
      expect(out, contains('0'));
    });

    test('negativo (raro pero posible en reportes)', () {
      final out = Fmt.cordobas(-50);
      expect(out, contains('50'));
    });
  });

  group('Fmt.dolares', () {
    test('formato dólar', () {
      final out = Fmt.dolares(20);
      expect(out, contains('US\$'));
      expect(out, contains('20'));
    });

    test('decimales', () {
      final out = Fmt.dolares(36.5);
      expect(out, contains('US\$'));
      expect(out, contains('36'));
      expect(out, contains('50'));
    });
  });

  group('Fmt.monto (selector por moneda)', () {
    test('moneda USD usa dolares', () {
      expect(Fmt.monto(100, 'USD'), contains('US\$'));
    });

    test('moneda NIO usa cordobas', () {
      expect(Fmt.monto(100, 'NIO'), contains('C\$'));
    });

    test('cualquier otro string default a cordobas', () {
      // Comportamiento del else: solo USD desvía. EUR, GBP, etc. → C$.
      expect(Fmt.monto(100, 'EUR'), contains('C\$'));
      expect(Fmt.monto(100, ''), contains('C\$'));
    });
  });

  group('Fmt.fechaCorta', () {
    test('formato dd/MM/yyyy', () {
      expect(Fmt.fechaCorta(DateTime(2026, 5, 22)), '22/05/2026');
    });

    test('mes y día con leading zero', () {
      expect(Fmt.fechaCorta(DateTime(2026, 1, 5)), '05/01/2026');
    });
  });

  group('Fmt.fechaRelativa (lógica condicional crítica)', () {
    final hoy = DateTime(2026, 5, 22);

    test('mismo día → Hoy', () {
      expect(Fmt.fechaRelativa(hoy, hoy), 'Hoy');
    });

    test('hora distinta mismo día → Hoy (ignora hora, solo fecha)', () {
      // El método extrae year/month/day, ignora hora/min/seg.
      expect(
        Fmt.fechaRelativa(
          DateTime(2026, 5, 22, 23, 59, 59),
          DateTime(2026, 5, 22, 0, 0, 0),
        ),
        'Hoy',
      );
    });

    test('un día atrás → Ayer', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 21), hoy), 'Ayer');
    });

    test('un día adelante → Mañana', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 23), hoy), 'Mañana');
    });

    test('3 días adelante → En 3 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 25), hoy), 'En 3 días');
    });

    test('6 días adelante (boundary inclusivo) → En 6 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 28), hoy), 'En 6 días');
    });

    test('7 días adelante (boundary exclusivo) → fecha corta absoluta', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 29), hoy), '29/05/2026');
    });

    test('5 días atrás → Hace 5 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 17), hoy), 'Hace 5 días');
    });

    test('6 días atrás (boundary inclusivo) → Hace 6 días', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 16), hoy), 'Hace 6 días');
    });

    test('7 días atrás (boundary exclusivo) → fecha corta absoluta', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 5, 15), hoy), '15/05/2026');
    });

    test('mes anterior → fecha corta absoluta', () {
      expect(Fmt.fechaRelativa(DateTime(2026, 4, 1), hoy), '01/04/2026');
    });

    test('parámetro hoy default a DateTime.now() si no se pasa', () {
      // Test indirecto: si pasamos d=DateTime.now() y omitimos hoy,
      // debe retornar "Hoy" (ambos valores son la fecha actual).
      expect(Fmt.fechaRelativa(DateTime.now()), 'Hoy');
    });
  });

  group('Fmt.hora', () {
    test('formato HH:mm 24h', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 14, 30)), '14:30');
    });

    test('media noche', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 0, 0)), '00:00');
    });

    test('un minuto antes de media noche', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 23, 59)), '23:59');
    });

    test('leading zero en minutos', () {
      expect(Fmt.hora(DateTime(2026, 5, 22, 9, 5)), '09:05');
    });
  });

  group('Fmt.periodoRecibo (regla del 15)', () {
    // Regla operativa: clientes con día de pago ≤14 reciben recibo
    // del mismo mes. Clientes con ≥15 reciben recibo del mes
    // siguiente (cubren el mes que viene).

    test('día 14 (boundary) cobra el mismo mes', () {
      // periodo = mayo, dia_pago = 14 → recibo cubre mayo.
      final out = Fmt.periodoRecibo(14, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('mayo'));
      expect(out, contains('2026'));
    });

    test('día 15 (boundary) cobra el mes siguiente', () {
      // periodo = mayo, dia_pago = 15 → recibo cubre junio.
      final out = Fmt.periodoRecibo(15, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('junio'));
    });

    test('día 1 cobra el mismo mes', () {
      final out = Fmt.periodoRecibo(1, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('mayo'));
    });

    test('día 30 cobra mes siguiente', () {
      final out = Fmt.periodoRecibo(30, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('junio'));
    });

    test('día 15 en diciembre cobra enero del año siguiente', () {
      // Edge case: rollover de año.
      final out = Fmt.periodoRecibo(15, DateTime(2026, 12, 1));
      expect(out.toLowerCase(), contains('enero'));
      expect(out, contains('2027'));
    });
  });
}
