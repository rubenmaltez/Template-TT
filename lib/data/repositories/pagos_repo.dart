import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/pago.dart';

/// Resultado de un cobro exitoso. La UI navega a /recibo/[reciboId].
class CobroResultado {
  const CobroResultado({required this.pagoId, required this.reciboId});
  final String pagoId;
  final String reciboId;
}

class PagosRepo {
  PagosRepo();
  final _uuid = const Uuid();

  /// Registra un cobro: inserta pago + recibo en una transacción local.
  /// El trigger SQL del server actualizará cuota.monto_pagado/estado.
  ///
  /// El correlativo se calcula localmente como max(correlativo)+1 por
  /// (cobrador, prefijo). Cada cobrador tiene su propia secuencia, así
  /// que no hay colisión entre dispositivos offline.
  Future<CobroResultado> registrarCobro({
    required String tenantId,
    required String cobradorId,
    required String prefijoRecibo,
    required String cuotaId,
    required double montoCordobas,
    required Moneda moneda,
    required double montoOriginal,
    required double tasaConversion,
    required MetodoPago metodo,
    String? referencia,
    String? fotoComprobantePath,
    double? lat,
    double? lng,
    String? notas,
  }) async {
    final pagoId = _uuid.v4();
    final reciboId = _uuid.v4();
    final clientLocalIdPago = _uuid.v4();
    final clientLocalIdRecibo = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final correlativoCompleter = <int>[];

    await ps.db.writeTransaction((tx) async {
      // Calcular correlativo DENTRO de la transacción para evitar carrera
      // entre dos cobros simultáneos. Filtra anulado=0 para no agujerear
      // la secuencia con recibos descartados.
      final rows = await tx.getAll(
        '''
        SELECT COALESCE(MAX(correlativo), 0) + 1 AS prox
          FROM recibos
         WHERE cobrador_id = ? AND prefijo = ? AND anulado = 0
        ''',
        [cobradorId, prefijoRecibo],
      );
      final correlativo = (rows.first['prox'] as num).toInt();
      correlativoCompleter.add(correlativo);
      final numeroCompleto =
          '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

      await tx.execute(
        '''
        INSERT INTO pagos (
          id, tenant_id, cuota_id, cobrador_id,
          monto_cordobas, moneda, monto_original, tasa_conversion,
          metodo, referencia, foto_comprobante_path,
          lat, lng, notas, fecha_pago, anulado, client_local_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
        ''',
        [
          pagoId,
          tenantId,
          cuotaId,
          cobradorId,
          montoCordobas,
          moneda.value,
          montoOriginal,
          tasaConversion,
          metodo.value,
          referencia,
          fotoComprobantePath,
          lat,
          lng,
          notas,
          now,
          clientLocalIdPago,
        ],
      );

      await tx.execute(
        '''
        INSERT INTO recibos (
          id, tenant_id, pago_id, cobrador_id,
          prefijo, correlativo, numero_completo,
          reimpresiones, anulado, created_at, client_local_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)
        ''',
        [
          reciboId,
          tenantId,
          pagoId,
          cobradorId,
          prefijoRecibo,
          correlativo,
          numeroCompleto,
          now,
          clientLocalIdRecibo,
        ],
      );

      // Reflejar localmente el efecto del trigger server. Calculamos el
      // nuevo estado en Dart para no depender del orden de evaluación de
      // SET en SQLite (donde el CASE podría leer `monto_pagado` viejo o
      // nuevo según la versión).
      final cuotaRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (cuotaRows.isNotEmpty) {
        final monto = (cuotaRows.first['monto'] as num).toDouble();
        final pagadoViejo =
            (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
        final estadoActual = cuotaRows.first['estado'] as String;
        final pagadoNuevo = pagadoViejo + montoCordobas;
        final nuevoEstado = _calcularEstado(
            estadoActual: estadoActual,
            montoCuota: monto,
            pagadoNuevo: pagadoNuevo);
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, cuotaId],
        );
      }
    });

    return CobroResultado(pagoId: pagoId, reciboId: reciboId);
  }

  /// Anula un pago aplicando soft delete. También marca como anulados los
  /// recibos asociados. El trigger server recalcula cuota.monto_pagado/estado.
  Future<void> anularPago({
    required String pagoId,
    required String anuladoPorId,
    required String motivo,
  }) async {
    final now = DateTime.now().toIso8601String();
    await ps.db.writeTransaction((tx) async {
      // Snapshot del monto antes de marcar anulado, para ajustar cuota local.
      final pagoRows = await tx.getAll(
        'SELECT cuota_id, monto_cordobas FROM pagos WHERE id = ? AND anulado = 0',
        [pagoId],
      );
      if (pagoRows.isEmpty) return;
      final cuotaId = pagoRows.first['cuota_id'] as String;
      final monto = (pagoRows.first['monto_cordobas'] as num).toDouble();

      await tx.execute(
        '''
        UPDATE pagos
           SET anulado = 1, anulado_en = ?, anulado_por = ?, motivo_anulacion = ?
         WHERE id = ?
        ''',
        [now, anuladoPorId, motivo, pagoId],
      );

      await tx.execute(
        '''
        UPDATE recibos
           SET anulado = 1, anulado_en = ?, anulado_por = ?
         WHERE pago_id = ? AND anulado = 0
        ''',
        [now, anuladoPorId, pagoId],
      );

      // Reflejar localmente el recálculo del trigger server.
      // Calculamos el nuevo estado en Dart (más predecible que CASE WHEN
      // con valores in-flight de SET).
      final cuotaRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (cuotaRows.isNotEmpty) {
        final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
        final pagadoViejo =
            (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
        final estadoActual = cuotaRows.first['estado'] as String;
        final pagadoNuevo = (pagadoViejo - monto).clamp(0, double.infinity);
        final nuevoEstado = _calcularEstado(
            estadoActual: estadoActual,
            montoCuota: montoCuota,
            pagadoNuevo: pagadoNuevo.toDouble());
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, cuotaId],
        );
      }
    });
  }

  /// Calcula el estado de una cuota en base al saldo, respetando 'anulada'.
  String _calcularEstado({
    required String estadoActual,
    required double montoCuota,
    required double pagadoNuevo,
  }) {
    if (estadoActual == 'anulada') return 'anulada';
    if (pagadoNuevo <= 0) return 'pendiente';
    if (pagadoNuevo >= montoCuota) return 'pagada';
    return 'parcial';
  }
}

final pagosRepoProvider = Provider((_) => PagosRepo());
