@TestOn('vm')
library;

/// Tests del repositorio de DINERO `PagosRepo` contra una PowerSyncDatabase
/// REAL (SQLite local), no un mock. Estos tests blindan los invariantes de
/// dinero de CLAUDE.md ("Invariantes de dinero") a nivel de la transacción que
/// el cobrador ejecuta offline: qué queda escrito en `pagos`, `recibos` y
/// `cuotas` después de cada flujo de cobro/anulación/edición.
///
/// ─────────────────────────────────────────────────────────────────────────
/// CÓMO CORRER (requiere el core nativo de PowerSync)
/// ─────────────────────────────────────────────────────────────────────────
/// `PowerSyncDatabase` necesita la extensión nativa `powersync-sqlite-core`
/// para abrir el SQLite local. Bajo `flutter test` (Dart VM, sin platform
/// channels) NO se resuelve sola: hay que tener el binario disponible.
///
/// 1. Descargá el binario de tu plataforma desde los releases de
///    `powersync-sqlite-core` (https://github.com/powersync-ja/powersync-sqlite-core/releases)
///    — debe coincidir con el rango que pide `powersync: ^1.10.0`.
///      - Linux:   `libpowersync.so`
///      - macOS:   `libpowersync.dylib`
///      - Windows: `powersync.dll`
/// 2. Dejalo en la RAÍZ del repo (junto a `pubspec.yaml`) con ese nombre.
///    El harness lo busca ahí por defecto; se puede overridear con la env var
///    `POWERSYNC_CORE_PATH=/ruta/al/libpowersync.so`.
/// 3. `flutter pub get` (trae `path` + `sqlite3` de dev_dependencies) y luego
///    `flutter test test/data/repositories/pagos_repo_test.dart`.
///
/// Si el binario no está, los tests se SALTAN con un mensaje claro (no fallan
/// en rojo por infraestructura faltante) — ver `_resolveCorePath`.
///
/// Nota de aislamiento: cada test abre su propia DB en un archivo temporal
/// único (carpeta del sistema), seedea su data, y la cierra/borra en tearDown.
/// No hay estado compartido entre tests ni red (la sesión Supabase no está
/// inicializada: el guard de correlativo que llama a `Supabase.instance`
/// cae en su `catch (_)` y usa el MAX(correlativo) LOCAL, que es justo lo que
/// queremos ejercitar).

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/models/pago.dart';
import 'package:isp_billing/data/repositories/pagos_repo.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
// Prefijado para evitar cualquier colisión con símbolos re-exportados por
// `powersync.dart` (que re-exporta parte de sqlite_async). Usamos `sq.open` y
// `sq.OperatingSystem` para apuntar la extensión nativa.
import 'package:sqlite3/open.dart' as sq;
import 'package:uuid/uuid.dart';

void main() {
  // ── Resolución del core nativo ────────────────────────────────────────────
  final corePath = _resolveCorePath();
  if (corePath == null) {
    test('PagosRepo (saltado: falta powersync-sqlite-core)', () {
      markTestSkipped(
        'No se encontró el binario `powersync-sqlite-core` en la raíz del repo '
        '(ni en \$POWERSYNC_CORE_PATH). Ver instrucciones en la cabecera de '
        'este archivo. Los tests de PagosRepo requieren el SQLite local de '
        'PowerSync para correr.',
      );
    }, skip: true);
    return;
  }

  // Registrar la extensión nativa para TODAS las plataformas que sqlite3 abre.
  // PowerSync usa `open.overrideFor` internamente; acá apuntamos al binario.
  for (final os in sq.OperatingSystem.values) {
    sq.open.overrideFor(os, () => DynamicLibrary.open(corePath));
  }

  const uuid = Uuid();

  // Helpers de seed/aserción que dependen de la DB del test actual.
  late PowerSyncDatabase db;
  late PagosRepo repo;
  late Directory tmpDir;

  // IDs base reutilizados por test (cada test corre sobre su DB limpia).
  const tenantId = 't-test';
  const cobradorId = 'co-test';
  const prefijo = 'A';
  const planId = 'plan-test';
  const clienteId = 'cli-test';

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('pagos_repo_test_');
    final dbPath = p.join(tmpDir.path, 'test_${uuid.v4()}.db');
    db = PowerSyncDatabase(schema: schema, path: dbPath);
    await db.initialize();
    repo = PagosRepo(db: db);

    // Seed mínimo común: tenant/cobrador(con prefijo)/plan/cliente.
    // El cobrador necesita `prefijo_recibo` para el correlativo del recibo.
    await db.execute(
      "INSERT INTO cobradores (id, tenant_id, nombre, rol, prefijo_recibo, activo) "
      "VALUES (?, ?, 'Cobrador Test', 'cobrador', ?, 1)",
      [cobradorId, tenantId, prefijo],
    );
    await db.execute(
      "INSERT INTO planes (id, tenant_id, nombre, tipo, precio_mensual, activo, created_at) "
      "VALUES (?, ?, 'Plan Test', 'fijo', 500, 1, ?)",
      [planId, tenantId, _now()],
    );
    await db.execute(
      "INSERT INTO clientes (id, tenant_id, cobrador_id, nombre, activo, created_at) "
      "VALUES (?, ?, ?, 'Cliente Test', 1, ?)",
      [clienteId, tenantId, cobradorId, _now()],
    );
  });

  tearDown(() async {
    await db.close();
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  // ── Helpers de seed específicos ─────────────────────────────────────────

  /// Crea un contrato y devuelve su id.
  Future<String> seedContrato({String? id}) async {
    final contratoId = id ?? uuid.v4();
    await db.execute(
      "INSERT INTO contratos (id, tenant_id, cliente_id, cobrador_id, plan_id, "
      "dia_pago, estado, created_at) "
      "VALUES (?, ?, ?, ?, ?, 5, 'activo', ?)",
      [contratoId, tenantId, clienteId, cobradorId, planId, _now()],
    );
    return contratoId;
  }

  /// Crea una cuota pendiente y devuelve su id.
  /// [monto] es el monto base; estado inicial 'pendiente', pagado 0.
  Future<String> seedCuota({
    required String contratoId,
    double monto = 500,
    String estado = 'pendiente',
    double montoPagado = 0,
    double cargosNeto = 0,
    String? id,
  }) async {
    final cuotaId = id ?? uuid.v4();
    await db.execute(
      "INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, cobrador_id, "
      "periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, created_at) "
      "VALUES (?, ?, ?, ?, ?, '2026-06', '2026-06-05', ?, ?, ?, ?, ?)",
      [
        cuotaId, tenantId, contratoId, clienteId, cobradorId,
        monto, montoPagado, cargosNeto, estado, _now(),
      ],
    );
    return cuotaId;
  }

  /// Inserta un cargo_extra sobre una cuota (reconexión suma, descuento resta).
  Future<void> seedCargo({
    required String cuotaId,
    required String tipo, // 'reconexion' | 'otro' | 'descuento_monto' | ...
    required double monto,
  }) async {
    await db.execute(
      "INSERT INTO cargos_extra (id, tenant_id, cuota_id, cobrador_id, tipo, "
      "monto, descripcion, aplicado_por, aplicado_en) "
      "VALUES (?, ?, ?, ?, ?, ?, 'seed', ?, ?)",
      [uuid.v4(), tenantId, cuotaId, cobradorId, tipo, monto, cobradorId, _now()],
    );
  }

  // ── Helpers de aserción (re-query a la DB) ──────────────────────────────

  Future<Map<String, dynamic>> getCuota(String cuotaId) async {
    final rows = await db.getAll('SELECT * FROM cuotas WHERE id = ?', [cuotaId]);
    expect(rows, hasLength(1), reason: 'cuota $cuotaId debe existir');
    return rows.first;
  }

  Future<Map<String, dynamic>> getPago(String pagoId) async {
    final rows = await db.getAll('SELECT * FROM pagos WHERE id = ?', [pagoId]);
    expect(rows, hasLength(1), reason: 'pago $pagoId debe existir');
    return rows.first;
  }

  Future<Map<String, dynamic>> getReciboDePago(String pagoId) async {
    final rows =
        await db.getAll('SELECT * FROM recibos WHERE pago_id = ?', [pagoId]);
    expect(rows, hasLength(1), reason: 'recibo del pago $pagoId debe existir');
    return rows.first;
  }

  double num2(Object? v) => (v as num).toDouble();

  // ───────────────────────────────────────────────────────────────────────
  // CASO 1 — registrarCobro completo (pago exacto)
  // ───────────────────────────────────────────────────────────────────────
  test('1. cobro completo 500/500: cuota pagada, monto_cordobas=500, '
      'vuelto=0, recibo correlativo 1', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500, // aplicado (ya separado por CobroCalculo)
      vueltoCordobas: 0,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 500);
    expect(cuota['estado'], 'pagada');

    final pago = await getPago(res.pagoId);
    expect(num2(pago['monto_cordobas']), 500); // entra a caja
    expect(num2(pago['vuelto_cordobas']), 0);
    expect(num2(pago['monto_original']), 500);
    expect(num2(pago['tasa_conversion']), 1);
    expect(pago['moneda'], 'NIO');
    expect(pago['anulado'], 0);

    final recibo = await getReciboDePago(res.pagoId);
    expect(recibo['correlativo'], 1);
    expect(recibo['numero_completo'], 'A-00001');
    expect(recibo['anulado'], 0);
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 2 — pago parcial
  // ───────────────────────────────────────────────────────────────────────
  test('2. cobro parcial 300/500: cuota parcial, monto_pagado=300', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 300,
      moneda: Moneda.nio,
      montoOriginal: 300,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 300);
    expect(cuota['estado'], 'parcial');

    final pago = await getPago(res.pagoId);
    expect(num2(pago['monto_cordobas']), 300);
    expect(num2(pago['vuelto_cordobas']), 0);
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 3 — sobrepago / vuelto (invariante #1/#4: recaudado SIN vuelto)
  // ───────────────────────────────────────────────────────────────────────
  test('3. sobrepago: entrega 600 sobre 500 → aplicado=500, vuelto=100, '
      'monto_pagado=500, cuota pagada', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    // El repo recibe ya separado el aplicado/vuelto (lo hace CobroCalculo en
    // la UI). Simulamos entrega de 600: aplicado=500, vuelto=100.
    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500, // aplicado = saldo (truncado)
      vueltoCordobas: 100, // excedente devuelto
      moneda: Moneda.nio,
      montoOriginal: 600, // lo entregado (NIO, tasa 1)
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    // monto_pagado SOLO refleja lo aplicado, nunca el vuelto.
    expect(num2(cuota['monto_pagado']), 500);
    expect(cuota['estado'], 'pagada');

    final pago = await getPago(res.pagoId);
    expect(num2(pago['monto_cordobas']), 500, reason: 'recaudado = aplicado');
    expect(num2(pago['vuelto_cordobas']), 100);
    // Invariante #3: monto_original × tasa ≈ monto_cordobas + vuelto.
    expect(
      num2(pago['monto_original']) * num2(pago['tasa_conversion']),
      closeTo(num2(pago['monto_cordobas']) + num2(pago['vuelto_cordobas']), 0.001),
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 4 — USD (vuelto SIEMPRE en NIO; invariante monto_original×tasa)
  // ───────────────────────────────────────────────────────────────────────
  test('4. USD: entrega US\$30 @ 36.6 sobre cuota 500 → monto_original=30, '
      'tasa=36.6, aplicado=500 NIO, vuelto=598 NIO', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    // US$30 @ 36.6 = 1098 NIO entregados; aplicado 500, vuelto 598 (NIO).
    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500, // aplicado en NIO
      vueltoCordobas: 598, // vuelto en NIO (nunca USD)
      moneda: Moneda.usd,
      montoOriginal: 30, // lo entregado en USD
      tasaConversion: 36.6,
      metodo: MetodoPago.efectivo,
    );

    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 500);
    expect(cuota['estado'], 'pagada');

    final pago = await getPago(res.pagoId);
    expect(pago['moneda'], 'USD');
    expect(num2(pago['monto_original']), 30);
    expect(num2(pago['tasa_conversion']), 36.6);
    expect(num2(pago['monto_cordobas']), 500);
    expect(num2(pago['vuelto_cordobas']), 598);
    // Invariante #3: 30 × 36.6 = 1098 ≈ 500 + 598.
    expect(
      num2(pago['monto_original']) * num2(pago['tasa_conversion']),
      closeTo(num2(pago['monto_cordobas']) + num2(pago['vuelto_cordobas']), 0.001),
    );
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 5 — cargos_extra: el saldo respeta monto + cargos − descuentos
  // ───────────────────────────────────────────────────────────────────────
  group('5. cargos_extra (saldo = monto + cargos − descuentos)', () {
    test('reconexión +100: pagar 600 (500 base + 100 cargo) deja cuota pagada '
        'y cargos_neto=100', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'reconexion', monto: 100);

      // Saldo real = 500 + 100 = 600. Cobro completo aplica 600.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 600,
        moneda: Moneda.nio,
        montoOriginal: 600,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), 100, reason: 'mirror del trigger neto');
      expect(num2(cuota['monto_pagado']), 600);
      // total real = 500 + 100 = 600 → pagada.
      expect(cuota['estado'], 'pagada');

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 600);
    });

    test('reconexión +100 pero solo paga 500 (base): queda parcial '
        '(faltan los 100 del cargo)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'reconexion', monto: 100);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), 100);
      expect(num2(cuota['monto_pagado']), 500);
      // total real 600, pagado 500 → parcial.
      expect(cuota['estado'], 'parcial');
      expect(res.reciboId, isNotEmpty);
    });

    test('descuento_monto −100: pagar 400 deja la cuota pagada '
        'y cargos_neto=-100', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'descuento_monto', monto: 100);

      // total real = 500 − 100 = 400.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 400,
        moneda: Moneda.nio,
        montoOriginal: 400,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), -100);
      expect(num2(cuota['monto_pagado']), 400);
      expect(cuota['estado'], 'pagada');

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 400);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 6 — registrarCobroMultiple (2 cuotas, vuelto solo al último)
  // ───────────────────────────────────────────────────────────────────────
  test('6. multi-cuota: 2 cuotas del mismo contrato, pago total con vuelto → '
      'ambas pagadas, vuelto solo al ÚLTIMO pago, correlativos consecutivos',
      () async {
    final contratoId = await seedContrato();
    final cuotaA = await seedCuota(contratoId: contratoId, monto: 500);
    final cuotaB = await seedCuota(contratoId: contratoId, monto: 500);

    // Entrega 1200 sobre saldo 1000: aplica 500+500, vuelto 200 al último.
    final res = await repo.registrarCobroMultiple(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaIds: [cuotaA, cuotaB],
      montosCordobas: [500, 500],
      vueltoCordobas: 200,
      moneda: Moneda.nio,
      montosOriginal: [500, 700], // último carga su saldo + el excedente
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    expect(res.esMultiCuota, isTrue);
    expect(res.reciboIds, hasLength(2));
    expect(res.grupoCobro, isNotNull);

    // Ambas cuotas quedan pagadas.
    final ca = await getCuota(cuotaA);
    final cb = await getCuota(cuotaB);
    expect(ca['estado'], 'pagada');
    expect(cb['estado'], 'pagada');
    expect(num2(ca['monto_pagado']), 500);
    expect(num2(cb['monto_pagado']), 500);

    // Los pagos del grupo: el vuelto está SOLO en uno (el último), 0 en el otro.
    final pagosGrupo = await db.getAll(
      'SELECT * FROM pagos WHERE grupo_cobro = ? ORDER BY monto_original ASC',
      [res.grupoCobro],
    );
    expect(pagosGrupo, hasLength(2));
    // Σ monto_cordobas (recaudado) = 1000, SIN el vuelto.
    final recaudado =
        pagosGrupo.fold<double>(0, (a, r) => a + num2(r['monto_cordobas']));
    expect(recaudado, 1000, reason: 'recaudado NO incluye el vuelto (inv #4)');
    // El vuelto total (200) aparece una sola vez.
    final vueltoTotal =
        pagosGrupo.fold<double>(0, (a, r) => a + num2(r['vuelto_cordobas']));
    expect(vueltoTotal, 200);
    final filasConVuelto =
        pagosGrupo.where((r) => num2(r['vuelto_cordobas']) > 0).length;
    expect(filasConVuelto, 1, reason: 'vuelto solo en el último pago');
    // Todos comparten el mismo grupo_cobro.
    expect(pagosGrupo.every((r) => r['grupo_cobro'] == res.grupoCobro), isTrue);

    // Correlativos consecutivos 1 y 2 (sin colisión).
    final recibos = await db.getAll(
      'SELECT correlativo FROM recibos WHERE cobrador_id = ? AND prefijo = ? '
      'ORDER BY correlativo ASC',
      [cobradorId, prefijo],
    );
    expect(recibos.map((r) => r['correlativo']).toList(), [1, 2]);
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 7 — correlativo incremental sin colisión
  // ───────────────────────────────────────────────────────────────────────
  test('7. correlativo: dos cobros secuenciales → recibos 1 y 2', () async {
    final contratoId = await seedContrato();
    final c1 = await seedCuota(contratoId: contratoId, monto: 500);
    final c2 = await seedCuota(contratoId: contratoId, monto: 500);

    final r1 = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: c1,
      montoCordobas: 500,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );
    final r2 = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: c2,
      montoCordobas: 500,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    final rec1 = await getReciboDePago(r1.pagoId);
    final rec2 = await getReciboDePago(r2.pagoId);
    expect(rec1['correlativo'], 1);
    expect(rec2['correlativo'], 2);
    expect(rec1['numero_completo'], 'A-00001');
    expect(rec2['numero_completo'], 'A-00002');
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 8 — anularPago: restaura cuota, preserva pago (soft delete), recibo anulado
  // ───────────────────────────────────────────────────────────────────────
  test('8. anularPago: restaura monto_pagado/estado, pago preservado '
      '(anulado=1, no borrado), recibo anulado', () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    final res = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 500,
      moneda: Moneda.nio,
      montoOriginal: 500,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );

    // Pre-condición: cuota pagada.
    var cuota = await getCuota(cuotaId);
    expect(cuota['estado'], 'pagada');
    expect(num2(cuota['monto_pagado']), 500);

    await repo.anularPago(
      pagoId: res.pagoId,
      anuladoPorId: cobradorId,
      motivo: 'error de carga',
    );

    // Cuota restaurada a pendiente con pagado 0.
    cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 0);
    expect(cuota['estado'], 'pendiente');

    // El pago se PRESERVA (audit trail), marcado anulado.
    final pago = await getPago(res.pagoId);
    expect(pago['anulado'], 1);
    expect(pago['anulado_por'], cobradorId);
    expect(pago['motivo_anulacion'], 'error de carga');
    expect(pago['anulado_en'], isNotNull);
    // Sigue existiendo (no se borró).
    final pagoCount =
        await db.getAll('SELECT COUNT(*) AS n FROM pagos WHERE id = ?', [res.pagoId]);
    expect(pagoCount.first['n'], 1);

    // El recibo asociado queda anulado.
    final recibo = await getReciboDePago(res.pagoId);
    expect(recibo['anulado'], 1);
    expect(recibo['anulado_por'], cobradorId);
  });

  test('8b. anularPago sobre uno de un par parcial: queda parcial con el resto',
      () async {
    final contratoId = await seedContrato();
    final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

    // Dos pagos parciales de 250 → cuota pagada (500).
    final p1 = await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 250,
      moneda: Moneda.nio,
      montoOriginal: 250,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );
    await repo.registrarCobro(
      tenantId: tenantId,
      cobradorId: cobradorId,
      prefijoRecibo: prefijo,
      cuotaId: cuotaId,
      montoCordobas: 250,
      moneda: Moneda.nio,
      montoOriginal: 250,
      tasaConversion: 1,
      metodo: MetodoPago.efectivo,
    );
    expect((await getCuota(cuotaId))['estado'], 'pagada');

    // Anular el primero → queda 250 pagado → parcial.
    await repo.anularPago(
      pagoId: p1.pagoId,
      anuladoPorId: cobradorId,
      motivo: 'duplicado',
    );
    final cuota = await getCuota(cuotaId);
    expect(num2(cuota['monto_pagado']), 250);
    expect(cuota['estado'], 'parcial');
  });

  // ───────────────────────────────────────────────────────────────────────
  // CASO 9 — editarPago guard (vuelto>0 o moneda extranjera → excepción)
  // ───────────────────────────────────────────────────────────────────────
  group('9. editarPago guard (no permitido con vuelto / moneda extranjera)', () {
    test('editar pago con vuelto>0 → lanza excepción, no muta', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // Pago con vuelto (sobrepago 600 sobre 500).
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        vueltoCordobas: 100,
        moneda: Moneda.nio,
        montoOriginal: 600,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      await expectLater(
        repo.editarPago(pagoId: res.pagoId, montoCordobas: 400),
        throwsA(isA<Exception>()),
      );

      // No mutó: monto sigue 500.
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 500);
    });

    test('editar pago en moneda extranjera (USD) → lanza excepción', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 500,
        moneda: Moneda.usd,
        montoOriginal: 13.66,
        tasaConversion: 36.6,
        metodo: MetodoPago.efectivo,
      );

      await expectLater(
        repo.editarPago(pagoId: res.pagoId, montoCordobas: 400),
        throwsA(isA<Exception>()),
      );

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 500);
      expect(pago['moneda'], 'USD');
    });

    test('editar pago NIO sin vuelto: SÍ recalcula cuota '
        '(camino feliz, contraste del guard)', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // Pago parcial 300 (NIO, sin vuelto) → editable.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 300,
        moneda: Moneda.nio,
        montoOriginal: 300,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect((await getCuota(cuotaId))['estado'], 'parcial');

      // Subir el monto a 500 → cuota pagada, pago actualizado.
      await repo.editarPago(pagoId: res.pagoId, montoCordobas: 500);

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), 500);
      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['monto_pagado']), 500);
      expect(cuota['estado'], 'pagada');
    });
  });
}

String _now() => DateTime.now().toUtc().toIso8601String();

/// Busca el binario nativo `powersync-sqlite-core`:
///  1. `$POWERSYNC_CORE_PATH` si está seteada y el archivo existe.
///  2. En la raíz del repo, probando los nombres por plataforma.
/// Devuelve null si no lo encuentra (los tests se saltan en ese caso).
String? _resolveCorePath() {
  final override = Platform.environment['POWERSYNC_CORE_PATH'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  // La raíz del repo es el cwd cuando se corre `flutter test`.
  final root = Directory.current.path;
  final candidates = <String>[
    p.join(root, 'libpowersync.so'), // Linux
    p.join(root, 'libpowersync.dylib'), // macOS
    p.join(root, 'powersync.dll'), // Windows
    p.join(root, 'libpowersync_x64.so'),
    p.join(root, 'libpowersync_aarch64.so'),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
