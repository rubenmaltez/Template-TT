import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cobro_calculo.dart';

/// Tests de la matemática del cobro/vuelto. Esta es la lógica que tuvo el
/// bug crítico de contabilidad (se guardaba lo entregado como aplicado,
/// inflando el recaudado del contrato). Estos tests blindan los invariantes
/// de dinero documentados en CLAUDE.md.
void main() {
  group('CobroCalculo.calcular — pago exacto', () {
    test('entregado == saldo → aplicado=saldo, vuelto=0', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 500,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 500);
      expect(d.vueltoCordobas, 0);
      expect(d.tieneVuelto, isFalse);
      expect(d.entregadoCordobas, 500);
    });
  });

  group('CobroCalculo.calcular — pago con vuelto (el bug histórico)', () {
    test('cuota 500, cliente entrega 1000 → aplicado=500, vuelto=500', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 1000,
        saldoCordobas: 500,
      );
      // CRÍTICO: aplicado NO debe ser 1000 (ese era el bug que inflaba
      // el recaudado del contrato).
      expect(d.aplicadoCordobas, 500);
      expect(d.vueltoCordobas, 500);
      expect(d.tieneVuelto, isTrue);
      // Invariante: entregado = aplicado + vuelto.
      expect(d.entregadoCordobas, 1000);
    });

    test('cuota 500, cliente entrega 600 → aplicado=500, vuelto=100', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 600,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 500);
      expect(d.vueltoCordobas, 100);
    });
  });

  group('CobroCalculo.calcular — pago parcial (sin vuelto)', () {
    test('cuota 500, cliente entrega 300 → aplicado=300, vuelto=0', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 300,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 300);
      expect(d.vueltoCordobas, 0);
      expect(d.tieneVuelto, isFalse);
    });
  });

  group('CobroCalculo.calcular — multi-cuota (saldo agregado)', () {
    test('2 cuotas de 500 = saldo 1000, entrega 1200 → aplicado=1000, vuelto=200', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 1200,
        saldoCordobas: 1000,
      );
      expect(d.aplicadoCordobas, 1000);
      expect(d.vueltoCordobas, 200);
    });
  });

  group('CobroCalculo.aCordobas — conversión de moneda', () {
    test('NIO: tasa 1 → mismo monto', () {
      expect(CobroCalculo.aCordobas(500, 1), 500);
    });

    test('USD: 30 dólares a tasa 36.6 → 1098 córdobas', () {
      expect(CobroCalculo.aCordobas(30, 36.6), closeTo(1098, 0.001));
    });
  });

  group('CobroCalculo — USD con vuelto (regla: vuelto siempre en NIO)', () {
    test('cliente paga US\$30 (tasa 36.6) a cuota de 500 → aplicado=500, vuelto=598 NIO', () {
      final entregadoNio = CobroCalculo.aCordobas(30, 36.6); // 1098
      final d = CobroCalculo.calcular(
        entregadoCordobas: entregadoNio,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 500);
      // El vuelto se calcula y entrega en córdobas, nunca en dólares.
      expect(d.vueltoCordobas, closeTo(598, 0.001));
    });
  });

  group('CobroCalculo — guards defensivos', () {
    test('entregado negativo → clamp a 0', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: -100,
        saldoCordobas: 500,
      );
      expect(d.aplicadoCordobas, 0);
      expect(d.vueltoCordobas, 0);
    });

    test('saldo negativo → clamp a 0, todo es vuelto', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 500,
        saldoCordobas: -50,
      );
      expect(d.aplicadoCordobas, 0);
      expect(d.vueltoCordobas, 500);
    });

    test('saldo 0 (cuota ya pagada) → todo es vuelto', () {
      final d = CobroCalculo.calcular(
        entregadoCordobas: 500,
        saldoCordobas: 0,
      );
      expect(d.aplicadoCordobas, 0);
      expect(d.vueltoCordobas, 500);
    });
  });

  group('CobroCalculo — invariante entregado = aplicado + vuelto (siempre)', () {
    test('se cumple en una batería de combinaciones', () {
      final casos = <List<double>>[
        [100, 100], [100, 50], [50, 100], [0, 100], [100, 0],
        [1234.56, 1000], [999.99, 1000], [1000, 999.99],
      ];
      for (final c in casos) {
        final d = CobroCalculo.calcular(
          entregadoCordobas: c[0],
          saldoCordobas: c[1],
        );
        final entregadoEsperado = c[0] < 0 ? 0.0 : c[0];
        expect(d.aplicadoCordobas + d.vueltoCordobas,
            closeTo(entregadoEsperado, 0.001),
            reason: 'entregado=${c[0]} saldo=${c[1]}');
        // aplicado nunca excede el saldo.
        expect(d.aplicadoCordobas, lessThanOrEqualTo(c[1] < 0 ? 0.0 : c[1]) + 0.001);
        // nunca negativos.
        expect(d.aplicadoCordobas, greaterThanOrEqualTo(0));
        expect(d.vueltoCordobas, greaterThanOrEqualTo(0));
      }
    });
  });
}
