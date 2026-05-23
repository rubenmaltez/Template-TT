import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cuota_estado.dart';

/// Tests de `calcularEstadoCuota` — la lógica de estado de cuota
/// extraída de `PagosRepo._calcularEstado` en el sprint de tests base.
///
/// **Por qué es el primer test del repo**: la función espeja la SQL
/// `recalcular_cuota_desde_pagos` (migración 0007). Si la lógica
/// divergiera entre cliente y server, los pagos cambiarían el estado
/// de cuota de un lado pero no del otro — bug silencioso de alto
/// impacto (cuotas mostradas como pendientes cuando ya están pagadas,
/// o viceversa). Mirror crítico → top riesgo de regresión.
///
/// Cualquier cambio a esta función DEBE replicarse en la SQL del
/// server. Estos tests son el guardia ante divergencia.
void main() {
  group('calcularEstadoCuota', () {
    group('anuladas — siempre quedan anuladas (regla terminal)', () {
      test('anulada con pago cero queda anulada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'anulada',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'anulada',
        );
      });

      test('anulada con pago completo NO se reactiva como pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'anulada',
            montoCuota: 750.0,
            pagadoNuevo: 750.0,
            deltaCargosExtra: 0.0,
          ),
          'anulada',
        );
      });

      test('anulada con monto cero queda anulada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'anulada',
            montoCuota: 0.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'anulada',
        );
      });
    });

    group('pendientes — sin pago aún', () {
      test('pago cero → pendiente', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'pendiente',
        );
      });

      test('pago negativo (anulación de pago previo) → pendiente', () {
        // Edge case: un undo puede dejar el agregado en negativo
        // transitoriamente. La regla lo trata como sin pago.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: -10.0,
            deltaCargosExtra: 0.0,
          ),
          'pendiente',
        );
      });

      test('estadoActual previo no afecta cuando pagado<=0', () {
        // No importa de qué estado venga, si pagado=0 va a pendiente.
        for (final e in ['pendiente', 'parcial', 'pagada', 'en_gracia']) {
          expect(
            calcularEstadoCuota(
              estadoActual: e,
              montoCuota: 750.0,
              pagadoNuevo: 0.0,
              deltaCargosExtra: 0.0,
            ),
            'pendiente',
            reason: 'desde estado $e con pagado=0 debe ser pendiente',
          );
        }
      });
    });

    group('pagadas — pago cubre o excede el total', () {
      test('pago exacto al monto → pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 750.0,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });

      test('pago superior al monto → pagada', () {
        // El cliente paga de más (vuelto a su favor para próxima cuota).
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 1000.0,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });

      test('total cero (cuota gratis) con pago cero → pendiente NO pagada',
          () {
        // pagado=0 corta primero — antes de evaluar pagado>=total.
        // Regla: una cuota sin pagos jamás está "pagada" aunque el
        // total sea 0 por un descuento total.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 0.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: 0.0,
          ),
          'pendiente',
        );
      });

      test('total cero con pago positivo mínimo → pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 0.0,
            pagadoNuevo: 0.01,
            deltaCargosExtra: 0.0,
          ),
          'pagada',
        );
      });
    });

    group('parciales — pago entre 0 y total', () {
      test('pago menor al monto → parcial', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 300.0,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });

      test('pago muy chico → parcial', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 0.01,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });

      test('pago un centavo menos al monto → parcial', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 749.99,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
        );
      });
    });

    group('cargos extra positivos — recargos suben el total', () {
      test('recargo de 50 sobre 750 → total 800', () {
        // Pago de 750 (que cubría el monto base) ya no cubre el total.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 750.0,
            deltaCargosExtra: 50.0,
          ),
          'parcial',
        );
      });

      test('pago cubre monto + recargo exactamente → pagada', () {
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 800.0,
            deltaCargosExtra: 50.0,
          ),
          'pagada',
        );
      });
    });

    group('cargos extra negativos — descuentos bajan el total', () {
      test('descuento de 100 sobre 750 → total 650', () {
        // Con pago de 700 ya pasa el total descontado.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 700.0,
            deltaCargosExtra: -100.0,
          ),
          'pagada',
        );
      });

      test('descuento que supera el monto → total clamped a 0', () {
        // Cuota de 750 con descuento de 800 → total real 0 (no -50).
        // Pago de 0.01 ya la cubre.
        expect(
          calcularEstadoCuota(
            estadoActual: 'parcial',
            montoCuota: 750.0,
            pagadoNuevo: 0.01,
            deltaCargosExtra: -800.0,
          ),
          'pagada',
        );
      });

      test('descuento total exacto + pago cero → pendiente NO pagada', () {
        // Same lógica que test "total cero con pago cero": pagado=0
        // corta antes.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 750.0,
            pagadoNuevo: 0.0,
            deltaCargosExtra: -750.0,
          ),
          'pendiente',
        );
      });

      test('descuento menor al monto, pago parcial → parcial', () {
        // 1000 monto - 100 desc = 900 total. Pago 500 → parcial.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 1000.0,
            pagadoNuevo: 500.0,
            deltaCargosExtra: -100.0,
          ),
          'parcial',
        );
      });
    });

    group('precisión floating point — números no enteros', () {
      test('0.1 + 0.2 ≈ 0.3 evita falsos parciales', () {
        // Caso clásico de FP: 0.1 + 0.2 == 0.30000000000000004.
        // Si pagado=0.3 y total=0.3, la comparación >= debe matchear.
        expect(
          calcularEstadoCuota(
            estadoActual: 'pendiente',
            montoCuota: 0.1 + 0.2,
            pagadoNuevo: 0.3,
            deltaCargosExtra: 0.0,
          ),
          'parcial',
          reason: 'Doc del comportamiento actual: 0.3 < 0.30000000000000004 '
              '→ parcial. Si en el futuro queremos tolerancia epsilon, '
              'agregar epsilon explícito acá y en la SQL del server.',
        );
      });
    });
  });
}
