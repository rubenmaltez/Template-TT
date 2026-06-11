import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../powersync/db.dart' as ps;
import '../models/pago.dart';
import '../services/correlativo_store.dart';
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
              cargo.descripcion, cobradorId, now, _uuid.v4(),
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
              cargo.descripcion, cobradorId, now, _uuid.v4(),
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
      // los DESCUENTOS que ESTE cobro insertó (pronto pago / manual del
      // flujo de cobro con pago_id) se borran — sin esto, la cuota quedaba
      // con el total rebajado para siempre. La reconexión se preserva a
      // propósito (se sigue debiendo). Cargos históricos (pago_id NULL)
      // no se tocan.
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
