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

      // Reflejar localmente el efecto del trigger server: sumar al saldo
      // de la cuota y actualizar estado. Cuando llegue el sync, el server
      // recalcula desde la verdad (todos los pagos no anulados).
      await tx.execute(
        '''
        UPDATE cuotas
           SET monto_pagado = monto_pagado + ?,
               estado = CASE
                          WHEN monto_pagado + ? >= monto THEN 'pagada'
                          WHEN monto_pagado + ? > 0     THEN 'parcial'
                          ELSE estado
                        END
         WHERE id = ?
        ''',
        [montoCordobas, montoCordobas, montoCordobas, cuotaId],
      );
    });

    return CobroResultado(pagoId: pagoId, reciboId: reciboId);
  }
}

final pagosRepoProvider = Provider((_) => PagosRepo());
