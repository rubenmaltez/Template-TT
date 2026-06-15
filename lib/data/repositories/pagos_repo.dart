import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/pago.dart';
import '../services/correlativo_store.dart';
import '../utils/cuota_estado.dart';
import '../utils/prorrateo.dart';

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
  /// [db] permite inyectar una `PowerSyncDatabase` para tests. En producción
  /// queda null y el repo usa la global `ps.db` (no se cambia el wiring).
  PagosRepo({PowerSyncDatabase? db}) : _db = db;
  final _uuid = const Uuid();
  final PowerSyncDatabase? _db;
  PowerSyncDatabase get _dbOrGlobal => _db ?? ps.db;

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
    double vueltoCordobas = 0,
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
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final correlativoEmitido = <int>[];

    // Guard correlativo: SIEMPRE consultar el server para el MAX porque
    // los recibos anulados no se sincronizan al cobrador (sync rules
    // filtran anulado = false), pero el server SÍ los tiene. Con timeout
    // corto: sin él, una señal degradada (1 raya / portal cautivo) colgaba
    // el flujo de COBRO varios minutos (audit 2026-06-11 M6); el catch
    // degrada al guard local. Complemento OFFLINE: el high-water mark de
    // CorrelativoStore nunca decrece — cubre el caso "recibo anulado recién
    // removido del SQLite por el sync + sin señal", donde el MAX local baja
    // y se reimprimía un número ya emitido (audit #2).
    int? _pisoCorrelativo;
    try {
      final serverRows = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (serverRows.isNotEmpty) {
        _pisoCorrelativo = (serverRows.first['correlativo'] as num).toInt();
      }
    } catch (_) {}
    if (_pisoCorrelativo != null) {
      // Reflejar en el hwm lo emitido desde OTROS dispositivos.
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, _pisoCorrelativo);
    }
    final hwmLocal = await CorrelativoStore.leer(cobradorId, prefijoRecibo);

    await _dbOrGlobal.writeTransaction((tx) async {
      if (cargosAuto != null) {
        for (final cargo in cargosAuto) {
          await tx.execute(
            '''
            INSERT INTO cargos_extra (
              id, tenant_id, cuota_id, cobrador_id, tipo, monto,
              porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id,
              ocurrido_en, origen, pago_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'cobro', ?)
            ''',
            [
              _uuid.v4(), tenantId, cargo.cuotaId, cobradorId,
              cargo.tipo, cargo.monto, cargo.porcentaje,
              cargo.descripcion, cobradorId,
              // aplicado_en en UTC (B10; antes heredaba el local-naive de fecha_pago)
              ocurridoEn, _uuid.v4(),
              ocurridoEn,
              // pago_id (0115): liga el cargo automático a SU cobro para que
              // anularlo revierta los descuentos (M3) — trigger server + mirror.
              pagoId,
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
      final pisoServer = _pisoCorrelativo ?? 0;
      final piso = pisoServer > hwmLocal ? pisoServer : hwmLocal;
      final correlativo = (maxLocal > piso ? maxLocal : piso) + 1;
      correlativoEmitido.add(correlativo);
      final numeroCompleto =
          '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

      await tx.execute(
        '''
        INSERT INTO pagos (
          id, tenant_id, cuota_id, cobrador_id,
          monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion,
          metodo, referencia, foto_comprobante_path,
          lat, lng, notas, fecha_pago, anulado, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        ''',
        [
          pagoId,
          tenantId,
          cuotaId,
          cobradorId,
          montoCordobas,
          vueltoCordobas,
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
          ocurridoEn,
        ],
      );

      await tx.execute(
        '''
        INSERT INTO recibos (
          id, tenant_id, pago_id, cobrador_id,
          prefijo, correlativo, numero_completo,
          reimpresiones, anulado, created_at, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
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
          ocurridoEn,
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
        // M3-MONEY: el trigger Postgres `cargos_extra_actualizar_neto_trg`
        // (0023) mantiene cuotas.cargos_neto = SUM neta de cargos_extra.
        // Ese trigger corre recién al sync, así que offline reflejamos el
        // efecto localmente. `delta` ya es exactamente cargos_neto
        // (reconexion/otro suman, descuento_* restan).
        await tx.execute(
          'UPDATE cuotas SET cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
          [delta, ocurridoEn, cuotaId],
        );
        final nuevoEstado = calcularEstadoCuota(
          estadoActual: estadoActual,
          montoCuota: montoCuota,
          pagadoNuevo: pagadoNuevo,
          deltaCargosExtra: delta,
        );
        await tx.execute(
          'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, ocurridoEn, cuotaId],
        );
      }
    });

    // Persistir el high-water mark (best-effort, post-tx): si el sync luego
    // remueve este recibo (anulación del admin), el número no se reusa.
    if (correlativoEmitido.isNotEmpty) {
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, correlativoEmitido.last);
    }

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
    double vueltoCordobas = 0,
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
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final reciboIds = <String>[];
    String? primerPagoId;

    // Guard correlativo (mismo que registrarCobro: timeout + hwm local).
    int? _pisoMulti;
    try {
      final sr = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (sr.isNotEmpty) _pisoMulti = (sr.first['correlativo'] as num).toInt();
    } catch (_) {}
    if (_pisoMulti != null) {
      await CorrelativoStore.subirA(cobradorId, prefijoRecibo, _pisoMulti);
    }
    final hwmMulti = await CorrelativoStore.leer(cobradorId, prefijoRecibo);
    final correlativosEmitidos = <int>[];
    // IDs de pago precomputados: los cargos automáticos se insertan ANTES
    // del loop y necesitan ligarse al pago de SU cuota (pago_id, 0115/M3).
    final pagoIds = [for (var i = 0; i < cuotaIds.length; i++) _uuid.v4()];

    await _dbOrGlobal.writeTransaction((tx) async {
      // Insertar cargos automáticos (reconexión / pronto pago) antes de
      // los pagos para que el delta de cargos_extra ya los incluya.
      if (cargosAuto != null) {
        for (final cargo in cargosAuto) {
          await tx.execute(
            '''
            INSERT INTO cargos_extra (
              id, tenant_id, cuota_id, cobrador_id, tipo, monto,
              porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id,
              ocurrido_en, origen, pago_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'cobro', ?)
            ''',
            [
              _uuid.v4(), tenantId, cargo.cuotaId, cobradorId,
              cargo.tipo, cargo.monto, cargo.porcentaje,
              cargo.descripcion, cobradorId,
              // aplicado_en en UTC (B10; antes heredaba el local-naive de fecha_pago)
              ocurridoEn, _uuid.v4(),
              ocurridoEn,
              pagoIds[cuotaIds.indexOf(cargo.cuotaId)],
            ],
          );
        }
      }

      for (var i = 0; i < cuotaIds.length; i++) {
        final pagoId = pagoIds[i];
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
        final pisoSrv = _pisoMulti ?? 0;
        final pisoM = pisoSrv > hwmMulti ? pisoSrv : hwmMulti;
        final correlativo = (maxL > pisoM ? maxL : pisoM) + 1;
        correlativosEmitidos.add(correlativo);
        final numeroCompleto =
            '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

        // El vuelto sólo se asigna al ÚLTIMO pago del grupo (simplifica el
        // recibo: una sola línea de vuelto). Los demás pagos van con 0.
        final esUltimo = i == cuotaIds.length - 1;
        final vueltoPago = esUltimo ? vueltoCordobas : 0.0;

        await tx.execute(
          '''
          INSERT INTO pagos (
            id, tenant_id, cuota_id, cobrador_id,
            monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion,
            metodo, referencia, foto_comprobante_path,
            lat, lng, notas, fecha_pago, anulado, grupo_cobro, client_local_id,
            ocurrido_en
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
          ''',
          [
            pagoId, tenantId, cuotaIds[i], cobradorId,
            montosCordobas[i], vueltoPago, moneda.value, montosOriginal[i], tasaConversion,
            metodo.value, referencia, fotoComprobantePath,
            lat, lng, notas, now, grupoCobro, _uuid.v4(),
            ocurridoEn,
          ],
        );

        await tx.execute(
          '''
          INSERT INTO recibos (
            id, tenant_id, pago_id, cobrador_id,
            prefijo, correlativo, numero_completo,
            reimpresiones, anulado, created_at, client_local_id, ocurrido_en
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
          ''',
          [
            reciboId, tenantId, pagoId, cobradorId,
            prefijoRecibo, correlativo, numeroCompleto, now, _uuid.v4(),
            ocurridoEn,
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
          // M3-MONEY: mirror del trigger `cargos_extra_actualizar_neto_trg`
          // (0023). `delta` ya es cargos_neto (reconexion/otro suman,
          // descuento_* restan). Sin esto el saldo offline queda stale
          // hasta el sync.
          await tx.execute(
            'UPDATE cuotas SET cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
            [delta, ocurridoEn, cuotaIds[i]],
          );
          final nuevoEstado = calcularEstadoCuota(
            estadoActual: estadoActual,
            montoCuota: montoCuota,
            pagadoNuevo: pagadoNuevo,
            deltaCargosExtra: delta,
          );
          await tx.execute(
            'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
            [pagadoNuevo, nuevoEstado, ocurridoEn, cuotaIds[i]],
          );
        }
      }
    });

    // Persistir el high-water mark (best-effort, post-tx).
    if (correlativosEmitidos.isNotEmpty) {
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, correlativosEmitidos.last);
    }

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
    // Hora REAL del dispositivo en UTC — para el change log y los timestamps de
    // anulación (anulado_en del pago y del recibo), consistente entre sí (B10).
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbOrGlobal.writeTransaction((tx) async {
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
           SET anulado = 1, anulado_en = ?, anulado_por = ?, motivo_anulacion = ?,
               ocurrido_en = ?
         WHERE id = ?
        ''',
        [ocurridoEn, anuladoPorId, motivo, ocurridoEn, pagoId],
      );

      await tx.execute(
        '''
        UPDATE recibos
           SET anulado = 1, anulado_en = ?, anulado_por = ?, ocurrido_en = ?
         WHERE pago_id = ? AND anulado = 0
        ''',
        [ocurridoEn, anuladoPorId, ocurridoEn, pagoId],
      );

      // Mirror del trigger server trg_pagos_revertir_descuentos (0115, M3):
      // los DESCUENTOS que ESTE cobro insertó (pronto pago automático Y el
      // manual del cobrador — desde el rediseño 2026-06-11 ambos viajan
      // diferidos con pago_id) se borran — sin esto, la cuota quedaba con
      // el total rebajado para siempre. La reconexión y los cargos 'otro'
      // se preservan a propósito (se siguen debiendo). Sin pago_id no se
      // toca nada: solo cargos históricos pre-0115.
      await tx.execute(
        '''
        DELETE FROM cargos_extra
         WHERE pago_id = ?
           AND tipo IN ('descuento_monto', 'descuento_porcentaje')
        ''',
        [pagoId],
      );

      // Reflejar localmente el recálculo del trigger server, considerando
      // cargos_extra (descuentos restan, reconexión/otro suman). El delta se
      // lee DESPUÉS del DELETE de arriba, así que cargos_neto también espeja
      // la reversión.
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
          'UPDATE cuotas SET monto_pagado = ?, estado = ?, cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
          [pagadoNuevo, nuevoEstado, delta, ocurridoEn, cuotaId],
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
    // Hora REAL del dispositivo (UTC) para el change log — offline-first.
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    await _dbOrGlobal.writeTransaction((tx) async {
      // Leer el pago actual para obtener cuota_id y monto previo.
      final pagoRows = await tx.getAll(
        'SELECT cuota_id, monto_cordobas, vuelto_cordobas, moneda FROM pagos WHERE id = ? AND anulado = 0',
        [pagoId],
      );
      if (pagoRows.isEmpty) {
        throw Exception('Pago no encontrado o ya anulado');
      }
      // Defense in depth: editar un pago con vuelto dejaría el vuelto
      // inconsistente con el nuevo monto. El flujo correcto es anular +
      // recobrar. El UI ya bloquea el botón, esto cubre cualquier callsite.
      final vueltoPrevio =
          (pagoRows.first['vuelto_cordobas'] as num? ?? 0).toDouble();
      if (vueltoPrevio > 0) {
        throw Exception(
          'No se puede editar un pago con vuelto. Anulalo y registrá el cobro de nuevo.',
        );
      }
      // Defense in depth (F1): el editor solo captura monto en córdobas; editar
      // un pago en moneda extranjera lo dejaría con monto_original en C$ y
      // tasa=1.0, corrompiendo el rastro de moneda (invariante #3). El flujo
      // correcto es anular + recobrar. El UI ya bloquea el botón.
      final monedaPrevia = pagoRows.first['moneda'] as String? ?? 'NIO';
      if (monedaPrevia != 'NIO') {
        throw Exception(
          'No se puede editar un pago en moneda extranjera. Anulalo y registrá el cobro de nuevo.',
        );
      }
      final cuotaId = pagoRows.first['cuota_id'] as String;
      final montoPrevio = (pagoRows.first['monto_cordobas'] as num).toDouble();

      // Tope contra el saldo (M2, audit 2026-06-11): sin esto, un typo del
      // admin (500 → 5000) inflaba el recaudado en silencio — el trigger
      // server tampoco lo limita (marca 'pagada' y guarda el sobrepago, que
      // recién aparecía corriendo invariantes_dinero.sql INV4). El máximo
      // editable = total de la cuota (monto + cargos_neto) menos lo pagado
      // por LOS DEMÁS pagos (pagado actual − este pago).
      if (montoCordobas != null && montoCordobas != montoPrevio) {
        final topeRows = await tx.getAll(
          'SELECT monto, cargos_neto, monto_pagado FROM cuotas WHERE id = ?',
          [cuotaId],
        );
        if (topeRows.isNotEmpty) {
          final r = topeRows.first;
          final total = (r['monto'] as num).toDouble() +
              ((r['cargos_neto'] as num?)?.toDouble() ?? 0.0);
          final pagadoOtros =
              ((r['monto_pagado'] as num?)?.toDouble() ?? 0.0) - montoPrevio;
          final maximo = total - pagadoOtros;
          if (montoCordobas > maximo + 0.01) {
            throw Exception(
              'El monto excede el saldo de la cuota: máximo '
              '${maximo.toStringAsFixed(2)} (la cuota quedaría sobrepagada).',
            );
          }
        }
      }

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

      // Estampar la hora de dispositivo de esta edición (solo si hubo cambios).
      sets.add('ocurrido_en = ?');
      params.add(ocurridoEn);

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
            'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
            [pagadoNuevo, nuevoEstado, ocurridoEn, cuotaId],
          );
        }
      }
    });
  }

  /// **Cambio de fecha de pago por días (feature C, Diseño A).**
  /// El cliente AL DÍA mueve su día de pago al [diaNuevo] y paga el "puente"
  /// (días prorrateados entre lo que pagó y el ancla del nuevo día). Todo OFFLINE
  /// en UNA writeTransaction:
  ///  1. `pagado hasta` = MAX(venc) de cuotas pagadas → host del cargo puente.
  ///  2. cobro del puente: cargos_extra origen='puente' tipo='otro' (SUMA) sobre
  ///     la última cuota pagada + pago + recibo + mirror (la cuota host sigue pagada).
  ///  3. absorbe (anula) las cuotas pendientes que caen DENTRO del puente.
  ///  4. re-fecha las futuras pendientes al día nuevo (espejo del trigger 0018).
  ///  5. UPDATE contratos.dia_pago (+ fecha_fin en fijos); en fijos agrega 1 cuota
  ///     de cierre al final por cada absorbida (conserva el conteo activo).
  ///
  /// El monto aplicado del puente lo determina el helper [calcularPuenteCambioFecha]
  /// (NO el caller): el caller pasa lo ENTREGADO ([montoOriginal] en [moneda] a
  /// [tasaConversion]); el vuelto se calcula. Requiere RLS+guard de 0119.
  Future<CobroResultado> registrarCambioFecha({
    required String tenantId,
    required String cobradorId,
    required String prefijoRecibo,
    required String contratoId,
    required int diaNuevo,
    required double precioMensual,
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
  }) async {
    final pagoId = _uuid.v4();
    final reciboId = _uuid.v4();
    final clientLocalIdPago = _uuid.v4();
    final clientLocalIdRecibo = _uuid.v4();
    final now = (fechaPago ?? DateTime.now()).toIso8601String();
    final ocurridoEn = DateTime.now().toUtc().toIso8601String();
    final correlativoEmitido = <int>[];

    // Guard de correlativo: mismo patrón que registrarCobro (server MAX con
    // timeout corto → hwm local de fallback).
    int? pisoCorrelativo;
    try {
      final serverRows = await Supabase.instance.client
          .from('recibos')
          .select('correlativo')
          .eq('cobrador_id', cobradorId)
          .eq('prefijo', prefijoRecibo)
          .order('correlativo', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (serverRows.isNotEmpty) {
        pisoCorrelativo = (serverRows.first['correlativo'] as num).toInt();
      }
    } catch (_) {}
    if (pisoCorrelativo != null) {
      await CorrelativoStore.subirA(cobradorId, prefijoRecibo, pisoCorrelativo);
    }
    final hwmLocal = await CorrelativoStore.leer(cobradorId, prefijoRecibo);

    await _dbOrGlobal.writeTransaction((tx) async {
      // 0. Contrato: día de pago viejo + cliente + duración (se usan desde acá).
      final contratoRows = await tx.getAll(
        'SELECT cliente_id, dia_pago, duracion_meses FROM contratos WHERE id = ?',
        [contratoId],
      );
      if (contratoRows.isEmpty) {
        throw StateError('Contrato no encontrado.');
      }
      final clienteId = contratoRows.first['cliente_id'] as String;
      final diaPagoViejo = (contratoRows.first['dia_pago'] as num).toInt();
      final duracionMeses =
          (contratoRows.first['duracion_meses'] as num?)?.toInt();
      final esFijo = duracionMeses != null && duracionMeses > 0;

      // Guard no-op: cambiar al MISMO día rodaría un mes entero (anclaServicio
      // siempre busca la PRIMERA ocurrencia estrictamente posterior) → cobraría
      // ~1 mes de puente y absorbería una cuota, para un cambio que no cambia nada.
      if (diaNuevo == diaPagoViejo) {
        throw StateError('El día nuevo es igual al día de pago actual.');
      }

      // 1. pagado hasta = día de servicio NOMINAL de la última cuota pagada: su
      //    período + el día viejo (clampeado), SIN el ajuste domingo→lunes que
      //    trae fecha_vencimiento (esa es la fecha de COBRO, no la de servicio).
      //    Usar fecha_vencimiento contaminaría el puente y la absorción cuando el
      //    día viejo cayó en domingo.
      final pagadasRows = await tx.getAll(
        '''
        SELECT id, periodo FROM cuotas
         WHERE contrato_id = ? AND estado = 'pagada'
         ORDER BY date(periodo) DESC
         LIMIT 1
        ''',
        [contratoId],
      );
      if (pagadasRows.isEmpty) {
        throw StateError(
            'El contrato no tiene cuotas pagadas: no se puede calcular el puente.');
      }
      final hostCuotaId = pagadasRows.first['id'] as String;
      final periodoHost = _parsePeriodo(pagadasRows.first['periodo'] as String);
      final pagadoHasta = DateTime(
        periodoHost.year,
        periodoHost.month,
        diaClampMes(periodoHost.year, periodoHost.month, diaPagoViejo),
      );

      // Guard "al día": ninguna cuota pendiente vencida (deuda) y ningún pago
      // parcial en curso (el re-fechado/absorción del trigger 0018 sólo toca
      // 'pendiente'; un 'parcial' quedaría inconsistente).
      final deudaRows = await tx.getAll(
        '''
        SELECT COUNT(*) AS n FROM cuotas
         WHERE contrato_id = ?
           AND estado IN ('pendiente','parcial')
           AND date(fecha_vencimiento) <= date('now','-6 hours')
        ''',
        [contratoId],
      );
      if ((deudaRows.first['n'] as num).toInt() > 0) {
        throw StateError('El cliente no está al día (cuotas vencidas o parciales).');
      }
      final parcialRows = await tx.getAll(
        "SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ? AND estado = 'parcial'",
        [contratoId],
      );
      if ((parcialRows.first['n'] as num).toInt() > 0) {
        throw StateError('Hay un pago parcial en curso: no se puede cambiar la fecha.');
      }

      // 2. Puente.
      final puente = calcularPuenteCambioFecha(
        pagadoHasta: pagadoHasta,
        diaNuevo: diaNuevo,
        precioMensual: precioMensual,
      );
      final aplicado = puente.montoPuente;
      if (aplicado <= 0) {
        throw StateError('El puente no aplica (el día nuevo no es posterior a lo pagado).');
      }
      final aplicadoCent = (aplicado * 100).round();
      final entregadoCent = (montoOriginal * tasaConversion * 100).round();
      if (entregadoCent < aplicadoCent) {
        throw StateError('El monto entregado no alcanza para el puente.');
      }
      final vuelto = (entregadoCent - aplicadoCent) / 100.0;

      // 3a. Cargo puente sobre la cuota host (origen='puente', tipo='otro' SUMA).
      await tx.execute(
        '''
        INSERT INTO cargos_extra (
          id, tenant_id, cuota_id, cobrador_id, tipo, monto,
          porcentaje, descripcion, aplicado_por, aplicado_en, client_local_id,
          ocurrido_en, origen, pago_id
        ) VALUES (?, ?, ?, ?, 'otro', ?, NULL, ?, ?, ?, ?, ?, 'puente', ?)
        ''',
        [
          _uuid.v4(), tenantId, hostCuotaId, cobradorId, aplicado,
          'Puente de pago (cambio de fecha al día $diaNuevo)',
          cobradorId, ocurridoEn, _uuid.v4(), ocurridoEn, pagoId,
        ],
      );

      // 3b. Correlativo dentro de la tx (sin filtrar anulados).
      final rows = await tx.getAll(
        'SELECT COALESCE(MAX(correlativo), 0) AS max_local FROM recibos WHERE cobrador_id = ? AND prefijo = ?',
        [cobradorId, prefijoRecibo],
      );
      final maxLocal = (rows.first['max_local'] as num).toInt();
      final pisoServer = pisoCorrelativo ?? 0;
      final piso = pisoServer > hwmLocal ? pisoServer : hwmLocal;
      final correlativo = (maxLocal > piso ? maxLocal : piso) + 1;
      correlativoEmitido.add(correlativo);
      final numeroCompleto =
          '$prefijoRecibo-${correlativo.toString().padLeft(5, '0')}';

      // 3c. Pago del puente (monto_cordobas = aplicado; vuelto en C$).
      await tx.execute(
        '''
        INSERT INTO pagos (
          id, tenant_id, cuota_id, cobrador_id,
          monto_cordobas, vuelto_cordobas, moneda, monto_original, tasa_conversion,
          metodo, referencia, foto_comprobante_path,
          lat, lng, notas, fecha_pago, anulado, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        ''',
        [
          pagoId, tenantId, hostCuotaId, cobradorId,
          aplicado, vuelto, moneda.value, montoOriginal, tasaConversion,
          metodo.value, referencia, fotoComprobantePath,
          lat, lng, notas, now, clientLocalIdPago, ocurridoEn,
        ],
      );

      // 3d. Recibo del puente.
      await tx.execute(
        '''
        INSERT INTO recibos (
          id, tenant_id, pago_id, cobrador_id,
          prefijo, correlativo, numero_completo,
          reimpresiones, anulado, created_at, client_local_id, ocurrido_en
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
        ''',
        [
          reciboId, tenantId, pagoId, cobradorId,
          prefijoRecibo, correlativo, numeroCompleto,
          now, clientLocalIdRecibo, ocurridoEn,
        ],
      );

      // 3e. Mirror de la cuota host (sigue 'pagada': se le suma el puente al
      //     monto_pagado y al cargos_neto; total = monto + cargos_neto).
      final hostRows = await tx.getAll(
        'SELECT monto, monto_pagado, estado FROM cuotas WHERE id = ?',
        [hostCuotaId],
      );
      final montoCuota = (hostRows.first['monto'] as num).toDouble();
      final pagadoViejo =
          (hostRows.first['monto_pagado'] as num? ?? 0).toDouble();
      final estadoActual = hostRows.first['estado'] as String;
      final pagadoNuevo = pagadoViejo + aplicado;
      final delta = await _deltaCargosExtra(tx, hostCuotaId);
      await tx.execute(
        'UPDATE cuotas SET cargos_neto = ?, ocurrido_en = ? WHERE id = ?',
        [delta, ocurridoEn, hostCuotaId],
      );
      final nuevoEstado = calcularEstadoCuota(
        estadoActual: estadoActual,
        montoCuota: montoCuota,
        pagadoNuevo: pagadoNuevo,
        deltaCargosExtra: delta,
      );
      await tx.execute(
        'UPDATE cuotas SET monto_pagado = ?, estado = ?, ocurrido_en = ? WHERE id = ?',
        [pagadoNuevo, nuevoEstado, ocurridoEn, hostCuotaId],
      );

      // 4. Absorber: cuotas pendientes cuyo servicio (día nuevo de su mes, sin
      //    ajuste domingo→lunes) NO es posterior al ancla → caen en el puente.
      final pendientes = await tx.getAll(
        "SELECT id, periodo FROM cuotas WHERE contrato_id = ? AND estado = 'pendiente'",
        [contratoId],
      );
      var absorbidas = 0;
      for (final c in pendientes) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final servicio = DateTime(periodo.year, periodo.month,
            diaClampMes(periodo.year, periodo.month, diaNuevo));
        if (!servicio.isAfter(puente.anclaServicio)) {
          await tx.execute(
            '''
            UPDATE cuotas
               SET estado = 'anulada', anulada_en = ?, anulada_por = ?,
                   motivo_anulacion = ?, ocurrido_en = ?
             WHERE id = ?
            ''',
            [
              ocurridoEn, cobradorId,
              'Absorbida por cambio de fecha de pago', ocurridoEn, c['id'],
            ],
          );
          absorbidas++;
        }
      }

      // 5. Re-fechar futuras pendientes al día nuevo (espejo del trigger 0018:
      //    periodo >= mes actual, estado='pendiente'; las absorbidas ya no son
      //    'pendiente' → no se tocan).
      final futuras = await tx.getAll(
        '''
        SELECT id, periodo FROM cuotas
         WHERE contrato_id = ? AND estado = 'pendiente'
           AND date(periodo) >= date('now','-6 hours','start of month')
        ''',
        [contratoId],
      );
      for (final c in futuras) {
        final periodo = _parsePeriodo(c['periodo'] as String);
        final venc = calcularFechaPago(periodo, diaNuevo);
        await tx.execute(
          'UPDATE cuotas SET fecha_vencimiento = ?, ocurrido_en = ? WHERE id = ?',
          [_fechaOnly(venc), ocurridoEn, c['id']],
        );
      }

      // 6. Contrato: cuota de cierre en fijos (1 por absorbida) + UPDATE dia_pago
      //    (+ fecha_fin en fijos, segura para limpiar_cuotas_excedentes).
      //    cliente_id / duracion_meses / esFijo se leyeron en el paso 0.
      if (esFijo && absorbidas > 0) {
        final maxRows = await tx.getAll(
          'SELECT MAX(date(periodo)) AS maxp FROM cuotas WHERE contrato_id = ?',
          [contratoId],
        );
        var ultimo = _parsePeriodo(maxRows.first['maxp'] as String);
        for (var i = 0; i < absorbidas; i++) {
          ultimo = DateTime(ultimo.year, ultimo.month + 1, 1);
          final venc = calcularFechaPago(ultimo, diaNuevo);
          await tx.execute(
            '''
            INSERT INTO cuotas (
              id, tenant_id, contrato_id, cliente_id, cobrador_id, periodo,
              fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, ocurrido_en
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 'pendiente', ?)
            ''',
            [
              _uuid.v4(), tenantId, contratoId, clienteId, cobradorId,
              _fechaOnly(ultimo), _fechaOnly(venc), precioMensual, ocurridoEn,
            ],
          );
        }
      }

      String? fechaFinNueva;
      if (esFijo) {
        final vencRows = await tx.getAll(
          "SELECT MAX(date(fecha_vencimiento)) AS maxv FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada'",
          [contratoId],
        );
        final maxv = vencRows.first['maxv'] as String?;
        if (maxv != null) {
          // +1 día: que la última cuota NO caiga en fecha_fin (limpiar_cuotas_
          // excedentes borra pendientes con venc >= fecha_fin al acortar).
          fechaFinNueva =
              _fechaOnly(DateTime.parse(maxv).add(const Duration(days: 1)));
        }
      }
      if (fechaFinNueva != null) {
        await tx.execute(
          'UPDATE contratos SET dia_pago = ?, fecha_fin = ?, ocurrido_en = ? WHERE id = ?',
          [diaNuevo, fechaFinNueva, ocurridoEn, contratoId],
        );
      } else {
        await tx.execute(
          'UPDATE contratos SET dia_pago = ?, ocurrido_en = ? WHERE id = ?',
          [diaNuevo, ocurridoEn, contratoId],
        );
      }
    });

    if (correlativoEmitido.isNotEmpty) {
      await CorrelativoStore.subirA(
          cobradorId, prefijoRecibo, correlativoEmitido.last);
    }
    return CobroResultado(pagoId: pagoId, reciboId: reciboId);
  }

  /// Parsea `periodo` (cuotas) a primer día del mes. Tolera 'YYYY-MM' y
  /// 'YYYY-MM-DD' (el server guarda date_trunc → 'YYYY-MM-01').
  DateTime _parsePeriodo(String s) {
    final p = s.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), 1);
  }

  /// Formatea una fecha como 'YYYY-MM-DD' (formato de las columnas date).
  String _fechaOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
}

final pagosRepoProvider = Provider((_) => PagosRepo());
