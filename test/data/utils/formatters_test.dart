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

    test('parámetro hoy default a DateTime.now() no lanza excepción', () {
      // Eliminado el test estricto que assertaba 'Hoy' — flaky por
      // racing con medianoche entre el now() capturado y el now() que
      // computa el default del param. Acá solo verificamos que la
      // función no rompe cuando se llama sin `hoy` — el valor de
      // retorno (Hoy/Ayer/Mañana según el momento) ya está cubierto
      // por los tests con `hoy:` explícito de arriba.
      expect(() => Fmt.fechaRelativa(DateTime.now()), returnsNormally);
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

  group('Fmt.periodoRecibo (facturación vencida)', () {
    // Modelo VENCIDA (validado con Rubén, ver Fmt.mesServicio): el recibo
    // muestra el MES DE SERVICIO, no el de vencimiento. El período cubierto va
    // del día de pago del mes anterior al día de vencimiento; se muestra el mes
    // que aporta MÁS días. `periodo` = primer día del mes de VENCIMIENTO.
    // Para un mes anterior de 30 días el umbral cae en el día 16 (≤15 → mes
    // anterior; ≥16 → mes de vencimiento), NO en 15 como la regla vieja.

    test('día 5: casi todo el período cae en el mes anterior → mes anterior', () {
      // venc 5/may → 26 días de abril vs 4 de mayo → abril.
      final out = Fmt.periodoRecibo(5, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('abril'));
      expect(out, contains('2026'));
    });

    test('día 15 (umbral bajo): el mes anterior aún aporta más → mes anterior', () {
      // venc 15/may → 16 días de abril vs 14 de mayo → abril.
      final out = Fmt.periodoRecibo(15, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('abril'));
    });

    test('día 16 (umbral alto): gana el mes de vencimiento → mes venc', () {
      // venc 16/may → 15 días de abril vs 15 de mayo → mayo (el empate va a venc).
      final out = Fmt.periodoRecibo(16, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('mayo'));
    });

    test('día 25: casi todo el período cae en el mes de vencimiento → mes venc', () {
      // venc 25/may → 6 días de abril vs 24 de mayo → mayo.
      final out = Fmt.periodoRecibo(25, DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('mayo'));
    });

    test('día 31 en febrero (doble clamp al último día real) → mes venc', () {
      // venc feb/2026 (no bisiesto, 28 días), día 31 → diaVenc=28, diaInicio=31
      // (clamp a 31 de enero) → 1 día de enero vs 27 de febrero → febrero.
      final out = Fmt.periodoRecibo(31, DateTime(2026, 2, 1));
      expect(out.toLowerCase(), contains('febrero'));
    });

    test('rollover de año: enero con día 15 → diciembre del año anterior', () {
      // venc 15/ene/2027 → 17 días de dic/2026 vs 14 de enero → diciembre 2026.
      final out = Fmt.periodoRecibo(15, DateTime(2027, 1, 1));
      expect(out.toLowerCase(), contains('diciembre'));
      expect(out, contains('2026'));
    });
  });

  group('Fmt.fechaLarga', () {
    test('formato legible con nombre de mes en español', () {
      final out = Fmt.fechaLarga(DateTime(2026, 5, 22));
      // Esperado: "22 de mayo de 2026"
      expect(out, contains('22'));
      expect(out.toLowerCase(), contains('mayo'));
      expect(out, contains('2026'));
      expect(out, contains('de'));
    });

    test('primer día del año', () {
      final out = Fmt.fechaLarga(DateTime(2026, 1, 1));
      expect(out, contains('1'));
      expect(out.toLowerCase(), contains('enero'));
      expect(out, contains('2026'));
    });

    test('último día del año', () {
      final out = Fmt.fechaLarga(DateTime(2026, 12, 31));
      expect(out, contains('31'));
      expect(out.toLowerCase(), contains('diciembre'));
      expect(out, contains('2026'));
    });

    test('día sin leading zero (formato d, no dd)', () {
      // El patrón es "d 'de' MMMM 'de' y" — día sin padding.
      final out = Fmt.fechaLarga(DateTime(2026, 3, 5));
      // Debe ser "5 de marzo de 2026", NO "05 de marzo de 2026".
      expect(out, startsWith('5'));
    });
  });

  group('Fmt.mes', () {
    test('formato MMMM y con nombre de mes en español', () {
      final out = Fmt.mes(DateTime(2026, 5, 1));
      expect(out.toLowerCase(), contains('mayo'));
      expect(out, contains('2026'));
    });

    test('enero', () {
      final out = Fmt.mes(DateTime(2026, 1, 15));
      expect(out.toLowerCase(), contains('enero'));
      expect(out, contains('2026'));
    });

    test('diciembre — boundary fin de año', () {
      final out = Fmt.mes(DateTime(2026, 12, 25));
      expect(out.toLowerCase(), contains('diciembre'));
      expect(out, contains('2026'));
    });

    test('ignora el día — solo muestra mes y año', () {
      // Dos fechas del mismo mes con días distintos deben dar idéntico output.
      final a = Fmt.mes(DateTime(2026, 7, 1));
      final b = Fmt.mes(DateTime(2026, 7, 31));
      expect(a, equals(b));
    });
  });

  group('Fmt.diaSemana', () {
    test('viernes — nombre completo en español con mayúscula inicial', () {
      // 22 de mayo 2026 es viernes.
      final out = Fmt.diaSemana(DateTime(2026, 5, 22));
      expect(out.toLowerCase(), equals('viernes'));
      // Verifica que la primera letra es mayúscula.
      expect(out[0], equals(out[0].toUpperCase()));
    });

    test('lunes — primer día laboral', () {
      // 25 de mayo 2026 es lunes.
      final out = Fmt.diaSemana(DateTime(2026, 5, 25));
      expect(out.toLowerCase(), equals('lunes'));
      expect(out[0], equals('L'));
    });

    test('domingo', () {
      // 24 de mayo 2026 es domingo.
      final out = Fmt.diaSemana(DateTime(2026, 5, 24));
      expect(out.toLowerCase(), equals('domingo'));
      expect(out[0], equals('D'));
    });

    test('capitalización — solo la primera letra es mayúscula', () {
      // El método hace [0].toUpperCase() + substring(1). Verificamos
      // que el resto está en minúscula (como viene de DateFormat).
      final out = Fmt.diaSemana(DateTime(2026, 5, 22));
      expect(out, equals(out[0].toUpperCase() + out.substring(1).toLowerCase()));
    });

    test('sábado — fin de semana', () {
      // 23 de mayo 2026 es sábado.
      final out = Fmt.diaSemana(DateTime(2026, 5, 23));
      expect(out.toLowerCase(), equals('sábado'));
      expect(out[0], equals('S'));
    });
  });
}
