import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/pago.dart';
import '../utils/cuota_estado.dart';

/// Resultado de un cobro exitoso. La UI navega a /recibo/[reciboId].
class CobroResultado {
  const CobroResultado({
    required this.pagoId,
    required this.reciboId,
    this.reciboIds,
    this.grupoCobro,
  });
  final String pagoId;
  final String reciboId;
  final List<String>? reciboIds;
  final String? grupoCobro;

  bool get esMultiCuota => reciboIds != null && reciboIds!.length > 1;
}

class CargoAutoInfo {
  const CargoAutoInfo({
    required this.cuotaId,
    required this.tipo,
    required this.monto,
    this.porcentaje,
    required this.descripcion,
  });
  final String cuotaId;
  final String tipo;
  final double monto;
  final double? porcentaje;
  final String descripcion;
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
    DateTime? fechaPago,
    List<CargoAutoInfo>? cargosAuto,
  }) async {
    final pagoId = _uuid.v4();
    final reciboId = _uuid.v4();
    final clientLocalIdPago = _uuid.v4();
    final clientLocalIdRecibo = _uuid.v4();
    final now = (fechaPago ?? DateTime.now()).toIso8601String();
    final correlativoCompleter = <int>[];

    // Guard correlativo: SIEMPRE consultar el server para el MAX porque
    // los recibos anulados no se sincronizan al cobrador (sync rules
    // filtran anulado = false), pero el server SÍ los tiene.
    int? _pisoCorrelativo;
    try {
      final serverRows = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1);
      if (serverRows.isNotEmpty) {
        _pisoCorrelativo = (serverRows.first['correlativo'] as num).toInt();
      }
    } catch (_) {}

    await ps.db.writeTransaction((tx) async {
      if (cargosAuto != null) {
        for (final cargo in cargosAuto) {
          await tx.execute(
            '''
            INSERT INTO cargos_extra (
              id, tenant_id, cuota_id, cobrador_id, tipo, monto,
              porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              _uuid.v4(), tenantId, cargo.cuotaId, cobradorId,
              cargo.tipo, cargo.monto, cargo.porcentaje,
              cargo.descripcion, cobradorId, now, _uuid.v4(),
            ],
          );
        }
      }

      // Calcular correlativo DENTRO de la transacción para evitar carrera
      // entre dos cobros simultáneos. NO filtramos anulado=0: si filtramos,
      // anular el recibo #1 hace que el próximo cobro reutilice el #1 y
      // colisiona con el unique constraint server (numero_completo).
      // La secuencia incluye anulados — quedan "huecos" referenciales OK.
      final rows = await tx.getAll(
        '''
        SELECT COALESCE(MAX(correlativo), 0) AS max_local
          FROM recibos
         WHERE cobrador_id = ? AND prefijo = ?
        ''',
        [cobradorId, prefijoRecibo],
      );
      final maxLocal = (rows.first['max_local'] as num).toInt();
      final piso = _pisoCorrelativo ?? 0;
      final correlativo = (maxLocal > piso ? maxLocal : piso) + 1;
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
      // nuevo estado en Dart espejando exactamente la lógica SQL de
      // `recalcular_cuota_desde_pagos` (migración 0018): el total real es
      // monto_cuota - descuentos + cargos. Sin esto, una cuota con
      // descuento podía mostrarse 'parcial' localmente y luego saltar a
      // 'pagada' cuando llegue el sync.
      final cuotaRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (cuotaRows.isNotEmpty) {
        final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
        final pagadoViejo =
            (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
        final estadoActual = cuotaRows.first['estado'] as String;
        final pagadoNuevo = pagadoViejo + montoCordobas;
        final delta = await _deltaCargosExtra(tx, cuotaId);
        final nuevoEstado = calcularEstadoCuota(
          estadoActual: estadoActual,
          montoCuota: montoCuota,
          pagadoNuevo: pagadoNuevo,
          deltaCargosExtra: delta,
        );
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, cuotaId],
        );
      }
    });

    return CobroResultado(pagoId: pagoId, reciboId: reciboId);
  }

  /// Registra un cobro multi-cuota: N pagos + N recibos en una sola
  /// transacción, todos vinculados por el mismo grupo_cobro UUID.
  /// Cada cuota recibe un pago por su saldo completo.
  Future<CobroResultado> registrarCobroMultiple({
    required String tenantId,
    required String cobradorId,
    required String prefijoRecibo,
    required List<String> cuotaIds,
    required List<double> montosCordobas,
    required Moneda moneda,
    required List<double> montosOriginal,
    required double tasaConversion,
    required MetodoPago metodo,
    String? referencia,
    String? fotoComprobantePath,
    double? lat,
    double? lng,
    String? notas,
    DateTime? fechaPago,
    List<CargoAutoInfo>? cargosAuto,
  }) async {
    assert(cuotaIds.length == montosCordobas.length);
    assert(cuotaIds.length == montosOriginal.length);

    final grupoCobro = _uuid.v4();
    final now = (fechaPago ?? DateTime.now()).toIso8601String();
    final reciboIds = <String>[];
    String? primerPagoId;

    // Guard correlativo (mismo que registrarCobro).
    int? _pisoMulti;
    try {
      final sr = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1);
      if (sr.isNotEmpty) _pisoMulti = (sr.first['correlativo'] as num).toInt();
    } catch (_) {}

    await ps.db.writeTransaction((tx) async {
      // Insertar cargos automáticos (reconexión / pronto pago) antes de
      // los pagos para que el delta de cargos_extra ya los incluya.
      if (cargosAuto != null) {
        for (final cargo in cargosAuto) {
          await tx.execute(
            '''
            INSERT INTO cargos_extra (
              id, tenant_id, cuota_id, cobrador_id, tipo, monto,
              porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              _uuid.v4(), tenantId, cargo.cuotaId, cobradorId,
              cargo.tipo, cargo.monto, cargo.porcentaje,
              cargo.descripcion, cobradorId, now, _uuid.v4(),
            ],
          );
        }
      }

      for (var i = 0; i < cuotaIds.length; i++) {
        final pagoId = _uuid.v4();
        final reciboId = _uuid.v4();
        primerPagoId ??= pagoId;
        reciboIds.add(reciboId);

        final rows = await tx.getAll(
          '''
          SELECT COALESCE(MAX(correlativo), 0) AS max_local
            FROM recibos
           WHERE cobrador_id = ? AND prefijo = ?
          ''',
          [cobradorId, prefijoRecibo],
        );
        final maxL = (rows.first['max_local'] as num).toInt();
        final pisoM = _pisoMulti ?? 0;
        final correlativo = (maxL > pisoM ? maxL : pisoM) + 1;
        final numeroCompleto =
            '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

        await tx.execute(
          '''
          INSERT INTO pagos (
            id, tenant_id, cuota_id, cobrador_id,
            monto_cordobas, moneda, monto_original, tasa_conversion,
            metodo, referencia, foto_comprobante_path,
            lat, lng, notas, fecha_pago, anulado, grupo_cobro, client_local_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
          ''',
          [
            pagoId, tenantId, cuotaIds[i], cobradorId,
            montosCordobas[i], moneda.value, montosOriginal[i], tasaConversion,
            metodo.value, referencia, fotoComprobantePath,
            lat, lng, notas, now, grupoCobro, _uuid.v4(),
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
            reciboId, tenantId, pagoId, cobradorId,
            prefijoRecibo, correlativo, numeroCompleto, now, _uuid.v4(),
          ],
        );

        // Reflejar localmente el efecto del trigger server.
        final cuotaRows = await tx.getAll(
          'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
          [cuotaIds[i]],
        );
        if (cuotaRows.isNotEmpty) {
          final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
          final pagadoViejo =
              (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
          final estadoActual = cuotaRows.first['estado'] as String;
          final pagadoNuevo = pagadoViejo + montosCordobas[i];
          final delta = await _deltaCargosExtra(tx, cuotaIds[i]);
          final nuevoEstado = calcularEstadoCuota(
            estadoActual: estadoActual,
            montoCuota: montoCuota,
            pagadoNuevo: pagadoNuevo,
            deltaCargosExtra: delta,
          );
          await tx.execute(
            'UPDATE cuotas SET monto_pagado = ?, estado = ? WHERE id = ?',
            [pagadoNuevo, nuevoEstado, cuotaIds[i]],
          );
        }
      }
    });

    return CobroResultado(
      pagoId: primerPagoId!,
      reciboId: reciboIds.first,
      reciboIds: reciboIds,
      grupoCobro: grupoCobro,
    );
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

      // Reflejar localmente el recálculo del trigger server, considerando
      // cargos_extra (descuentos restan, reconexión/otro suman).
      final cuotaRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
        [cuotaId],
      );
      if (cuotaRows.isNotEmpty) {
        final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
        final pagadoViejo =
            (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
        final estadoActual = cuotaRows.first['estado'] as String;
        final pagadoNuevo = (pagadoViejo - monto).clamp(0.0, double.infinity);
        final delta = await _deltaCargosExtra(tx, cuotaId);
        final nuevoEstado = calcularEstadoCuota(
          estadoActual: estadoActual,
          montoCuota: montoCuota,
          pagadoNuevo: pagadoNuevo.toDouble(),
          deltaCargosExtra: delta,
        );
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, cuotaId],
        );
      }
    });
  }

  /// Edita un pago existente (monto, método, notas). Solo actualiza los
  /// campos proporcionados. El trigger server recalcula cuota si el monto
  /// cambió. Localmente espejamos el recálculo igual que en registrarCobro.
  Future<void> editarPago({
    required String pagoId,
    double? montoCordobas,
    double? montoOriginal,
    double? tasaConversion,
    MetodoPago? metodo,
    String? notas,
    /// Pasar true para limpiar notas (null = no tocar).
    bool limpiarNotas = false,
  }) async {
    await ps.db.writeTransaction((tx) async {
      // Leer el pago actual para obtener cuota_id y monto previo.
      final pagoRows = await tx.getAll(
        'SELECT cuota_id, monto_cordobas FROM pagos WHERE id = ? AND anulado = 0',
        [pagoId],
      );
      if (pagoRows.isEmpty) {
        throw Exception('Pago no encontrado o ya anulado');
      }
      final cuotaId = pagoRows.first['cuota_id'] as String;
      final montoPrevio = (pagoRows.first['monto_cordobas'] as num).toDouble();

      // Construir SET clause dinámico.
      final sets = <String>[];
      final params = <Object?>[];
      if (montoCordobas != null) {
        sets.add('monto_cordobas = ?');
        params.add(montoCordobas);
      }
      if (montoOriginal != null) {
        sets.add('monto_original = ?');
        params.add(montoOriginal);
      }
      if (tasaConversion != null) {
        sets.add('tasa_conversion = ?');
        params.add(tasaConversion);
      }
      if (metodo != null) {
        sets.add('metodo = ?');
        params.add(metodo.value);
      }
      if (limpiarNotas) {
        sets.add('notas = NULL');
      } else if (notas != null) {
        sets.add('notas = ?');
        params.add(notas);
      }

      if (sets.isEmpty) return;

      params.add(pagoId);
      await tx.execute(
        'UPDATE pagos SET ${sets.join(', ')} WHERE id = ?',
        params,
      );

      // Si el monto cambió, recalcular estado de la cuota localmente
      // (mirror del trigger server).
      if (montoCordobas != null && montoCordobas != montoPrevio) {
        final cuotaRows = await tx.getAll(
          'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
          [cuotaId],
        );
        if (cuotaRows.isNotEmpty) {
          final montoCuota = (cuotaRows.first['monto'] as num).toDouble();
          final pagadoViejo =
              (cuotaRows.first['monto_pagado'] as num? ?? 0).toDouble();
          final estadoActual = cuotaRows.first['estado'] as String;
          // Ajustar: quitar el monto previo, sumar el nuevo.
          final pagadoNuevo = (pagadoViejo - montoPrevio + montoCordobas)
              .clamp(0.0, double.infinity);
          final delta = await _deltaCargosExtra(tx, cuotaId);
          final nuevoEstado = calcularEstadoCuota(
            estadoActual: estadoActual,
            montoCuota: montoCuota,
            pagadoNuevo: pagadoNuevo,
            deltaCargosExtra: delta,
          );
          await tx.execute(
            'UPDATE cuotas SET monto_pagado = ?, estado = ? WHERE id = ?',
            [pagadoNuevo, nuevoEstado, cuotaId],
          );
        }
      }
    });
  }

  /// Suma neta de cargos_extra de la cuota: cargos sumados (reconexion/otro)
  /// menos descuentos. Mirror del SQL `cuota_total_a_cobrar` (0018).
  Future<double> _deltaCargosExtra(dynamic tx, String cuotaId) async {
    final rows = await tx.getAll(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN tipo IN ('reconexion','otro')
                          THEN monto ELSE 0 END), 0) AS sumar,
        COALESCE(SUM(CASE WHEN tipo IN ('descuento_monto','descuento_porcentaje')
                          THEN monto ELSE 0 END), 0) AS restar
        FROM cargos_extra WHERE cuota_id = ?
      ''',
      [cuotaId],
    );
    final sumar = (rows.first['sumar'] as num).toDouble();
    final restar = (rows.first['restar'] as num).toDouble();
    return sumar - restar;
  }

  /// Recrea un pago que fue anulado por error. Crea un pago NUEVO
  /// (no desanula el viejo) con los mismos datos del original.
  Future<CobroResultado> recrearPago({
    required String pagoAnuladoId,
    required String tenantId,
    required String recreadorId,
    required String prefijoRecibo,
  }) async {
    final original = await ps.db.getAll(
      'SELECT * FROM pagos WHERE id = ?',
      [pagoAnuladoId],
    );
    if (original.isEmpty) throw Exception('Pago no encontrado');
    final p = original.first;

    // Guard: verificar que la cuota no esté ya pagada por otro pago.
    final cuotaRows = await ps.db.getAll(
      'SELECT estado FROM cuotas WHERE id = ?',
      [p['cuota_id']],
    );
    if (cuotaRows.isNotEmpty && cuotaRows.first['estado'] == 'pagada') {
      throw Exception('La cuota ya fue pagada por otro cobro');
    }

    return registrarCobro(
      tenantId: tenantId,
      cobradorId: recreadorId,
      prefijoRecibo: prefijoRecibo,
      cuotaId: p['cuota_id'] as String,
      montoCordobas: (p['monto_cordobas'] as num).toDouble(),
      moneda: Moneda.fromString(p['moneda'] as String),
      montoOriginal: (p['monto_original'] as num).toDouble(),
      tasaConversion: (p['tasa_conversion'] as num).toDouble(),
      metodo: MetodoPago.fromString(p['metodo'] as String),
      referencia: p['referencia'] as String?,
      notas: 'Recreado desde pago anulado $pagoAnuladoId',
    );
  }
}

final pagosRepoProvider = Provider((_) => PagosRepo());
