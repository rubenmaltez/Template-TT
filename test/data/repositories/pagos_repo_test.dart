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
///      - Windows: `powersync_x64.dll`  (OJO: powersync_core 1.18 carga la
///        extensión con el sufijo de arquitectura, NO `powersync.dll` como dicen
///        los docs viejos. Si tu versión difiere, mirá el nombre en el error
///        "Failed to load dynamic library '<nombre>'" y usá ese.)
///    Atajo recomendado: si `powersync_flutter_libs` ya está en el pub cache,
///    copiá su binario directo (garantiza versión compatible). En Windows:
///    `...\powersync_flutter_libs-<v>\windows\powersync_x64.dll`.
/// 2. Dejalo en la RAÍZ del repo (junto a `pubspec.yaml`) con ese nombre.
///    El harness lo busca ahí por defecto; se puede overridear con la env var
///    `POWERSYNC_CORE_PATH=/ruta/al/binario`.
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
import 'package:isp_billing/data/utils/prorrateo.dart';
import 'package:isp_billing/powersync/schema.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
// Prefijado para evitar cualquier colisión con símbolos re-exportados por
// `powersync.dart` (que re-exporta parte de sqlite_async). Usamos `sq.open` y
// `sq.OperatingSystem` para apuntar la extensión nativa.
import 'package:shared_preferences/shared_preferences.dart';
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
    // SharedPreferences en memoria y LIMPIO por test: el high-water mark del
    // correlativo (CorrelativoStore) no debe filtrar estado entre tests —
    // cada test arranca con hwm 0, igual que un dispositivo nuevo.
    SharedPreferences.setMockInitialValues({});
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

  /// Crea un contrato y devuelve su id. [duracionMeses] null = indefinido.
  Future<String> seedContrato({
    String? id,
    int diaPago = 5,
    int? duracionMeses,
    String? fechaFin,
  }) async {
    final contratoId = id ?? uuid.v4();
    await db.execute(
      "INSERT INTO contratos (id, tenant_id, cliente_id, cobrador_id, plan_id, "
      "dia_pago, duracion_meses, fecha_fin, estado, created_at) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'activo', ?)",
      [
        contratoId, tenantId, clienteId, cobradorId, planId,
        diaPago, duracionMeses, fechaFin, _now(),
      ],
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
    String periodo = '2026-06',
    String fechaVencimiento = '2026-06-05',
    String? id,
  }) async {
    final cuotaId = id ?? uuid.v4();
    await db.execute(
      "INSERT INTO cuotas (id, tenant_id, contrato_id, cliente_id, cobrador_id, "
      "periodo, fecha_vencimiento, monto, monto_pagado, cargos_neto, estado, created_at) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        cuotaId, tenantId, contratoId, clienteId, cobradorId,
        periodo, fechaVencimiento, monto, montoPagado, cargosNeto, estado, _now(),
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

    test('editar pago por ENCIMA del saldo de la cuota → lanza y no muta '
        '(M2: el typo 500→5000 inflaba el recaudado en silencio)', () async {
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

      // 5000 > total (500) − pagado por otros (0) → rechazado.
      await expectLater(
        repo.editarPago(pagoId: res.pagoId, montoCordobas: 5000),
        throwsA(isA<Exception>()),
      );
      // Nada mutó.
      expect(num2((await getPago(res.pagoId))['monto_cordobas']), 300);
      expect(num2((await getCuota(cuotaId))['monto_pagado']), 300);

      // El máximo exacto (500) SÍ pasa: completa la cuota.
      await repo.editarPago(pagoId: res.pagoId, montoCordobas: 500);
      expect((await getCuota(cuotaId))['estado'], 'pagada');
    });

    test('tope de edición considera cargos_neto y otros pagos de la cuota',
        () async {
      final contratoId = await seedContrato();
      // Cuota 500 + reconexión 100 → total 600.
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      await seedCargo(cuotaId: cuotaId, tipo: 'reconexion', monto: 100);

      final p1 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 200,
        moneda: Moneda.nio,
        montoOriginal: 200,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      final p2 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 100,
        moneda: Moneda.nio,
        montoOriginal: 100,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      // Editar p2: máximo = 600 − (300 − 100 de p2... = 200 de p1) = 400.
      await expectLater(
        repo.editarPago(pagoId: p2.pagoId, montoCordobas: 401),
        throwsA(isA<Exception>()),
      );
      await repo.editarPago(pagoId: p2.pagoId, montoCordobas: 400);
      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['monto_pagado']), 600); // 200 + 400 = total
      expect(cuota['estado'], 'pagada');
      expect(p1.pagoId, isNot(p2.pagoId));
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // GRUPO — high-water mark del correlativo (audit 2026-06-11, finding #2)
  // ─────────────────────────────────────────────────────────────────────
  group('correlativo: high-water mark local (CorrelativoStore)', () {
    test(
        'anulación sincronizada que borra el último recibo local NO reusa '
        'el número ya impreso', () async {
      final contratoId = await seedContrato();
      final cuota1 = await seedCuota(contratoId: contratoId, monto: 500);
      final cuota2 = await seedCuota(contratoId: contratoId, monto: 500);

      final res1 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuota1,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect((await getReciboDePago(res1.pagoId))['correlativo'], 1);

      // El admin anula el recibo en el server: las sync rules (filtran
      // anulado = false) hacen que PowerSync BORRE la fila del SQLite del
      // cobrador. Lo simulamos con un DELETE local directo.
      await db.execute('DELETE FROM recibos WHERE id = ?', [res1.reciboId]);

      // Sin hwm: MAX(correlativo) local = 0 y el piso server es inalcanzable
      // (sin sesión Supabase, como offline) → se reusaría el #1 ya impreso.
      final res2 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuota2,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      final recibo2 = await getReciboDePago(res2.pagoId);
      expect(recibo2['correlativo'], 2,
          reason: 'reusar el #1 duplicaría el número impreso del cliente y '
              'el server rechazaría el INSERT (23505) descartando el recibo');
      expect(recibo2['numero_completo'], 'A-00002');
    });

    test('multi-cuota también persiste el hwm (no reusa tras borrado local)',
        () async {
      final contratoId = await seedContrato();
      final cuota1 = await seedCuota(contratoId: contratoId, monto: 500);
      final cuota2 = await seedCuota(contratoId: contratoId, monto: 500);
      final cuota3 = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobroMultiple(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaIds: [cuota1, cuota2],
        montosCordobas: [500, 500],
        moneda: Moneda.nio,
        montosOriginal: [500, 500],
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      // Emitió #1 y #2; el sync remueve ambos (anulación masiva del admin).
      for (final rid in res.reciboIds!) {
        await db.execute('DELETE FROM recibos WHERE id = ?', [rid]);
      }

      final res2 = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuota3,
        montoCordobas: 500,
        moneda: Moneda.nio,
        montoOriginal: 500,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect((await getReciboDePago(res2.pagoId))['correlativo'], 3);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // GRUPO — reversión de descuentos al anular (audit 2026-06-11, M3 + 0115)
  // ─────────────────────────────────────────────────────────────────────
  group('anularPago revierte los descuentos del cobro (mirror de 0115)', () {
    test('descuento pronto-pago del cobro anulado se BORRA y el total de la '
        'cuota se restaura', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // Cobro con descuento automático de 100 → aplica 400 y queda pagada.
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
        cargosAuto: [
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'descuento_monto',
            monto: 100,
            descripcion: 'Descuento pronto pago',
          ),
        ],
      );
      var cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pagada');
      expect(num2(cuota['cargos_neto']), -100);

      // El cargo quedó ligado al pago (0115).
      final cargos = await db.getAll(
          'SELECT origen, pago_id FROM cargos_extra WHERE cuota_id = ?',
          [cuotaId]);
      expect(cargos, hasLength(1));
      expect(cargos.first['origen'], 'cobro');
      expect(cargos.first['pago_id'], res.pagoId);

      // Anular: el descuento se borra; total restaurado a 500 y pendiente.
      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      expect(
          await db.getAll(
              'SELECT id FROM cargos_extra WHERE cuota_id = ?', [cuotaId]),
          isEmpty,
          reason: 'el descuento nació con este cobro: anularlo lo revierte');
      cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pendiente');
      expect(num2(cuota['monto_pagado']), 0);
      expect(num2(cuota['cargos_neto']), 0);
    });

    test('la RECONEXIÓN del cobro anulado se PRESERVA (se sigue debiendo)',
        () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 600, // 500 + reconexión 100
        moneda: Moneda.nio,
        montoOriginal: 600,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
        cargosAuto: [
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'reconexion',
            monto: 100,
            descripcion: 'Cargo por reconexión',
          ),
        ],
      );
      expect((await getCuota(cuotaId))['estado'], 'pagada');

      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      final cargos = await db.getAll(
          'SELECT tipo FROM cargos_extra WHERE cuota_id = ?', [cuotaId]);
      expect(cargos, hasLength(1));
      expect(cargos.first['tipo'], 'reconexion');
      final cuota = await getCuota(cuotaId);
      expect(num2(cuota['cargos_neto']), 100); // la deuda de reconexión queda
      expect(cuota['estado'], 'pendiente');
    });

    test('descuento MANUAL diferido del cobro (rediseño 2026-06-11): viaja '
        'con pago_id + motivo, se revierte al anular; el cargo otro queda',
        () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);

      // El cobro inserta los pendientes de la pantalla: descuento manual
      // (con motivo) + cargo 'otro'. Total: 500 − 50 + 80 = 530.
      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 530,
        moneda: Moneda.nio,
        montoOriginal: 530,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
        cargosAuto: [
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'descuento_monto',
            monto: 50,
            descripcion: 'Acuerdo con el cliente',
          ),
          CargoAutoInfo(
            cuotaId: cuotaId,
            tipo: 'otro',
            monto: 80,
            descripcion: 'Cambio de conector',
          ),
        ],
      );
      var cuota = await getCuota(cuotaId);
      expect(cuota['estado'], 'pagada');
      expect(num2(cuota['cargos_neto']), 30); // +80 − 50

      // Ambos quedaron ligados al pago, con su motivo.
      final cargos = await db.getAll(
          'SELECT tipo, origen, pago_id, descripcion FROM cargos_extra '
          'WHERE cuota_id = ? ORDER BY tipo',
          [cuotaId]);
      expect(cargos, hasLength(2));
      for (final c in cargos) {
        expect(c['origen'], 'cobro');
        expect(c['pago_id'], res.pagoId);
        expect((c['descripcion'] as String).isNotEmpty, isTrue);
      }

      // Anular: el descuento manual se revierte (ya no hay "fantasma");
      // el cargo 'otro' se preserva (se sigue debiendo, como reconexión).
      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      final restantes = await db.getAll(
          'SELECT tipo FROM cargos_extra WHERE cuota_id = ?', [cuotaId]);
      expect(restantes, hasLength(1));
      expect(restantes.first['tipo'], 'otro');
      cuota = await getCuota(cuotaId);
      expect(num2(cuota['monto_pagado']), 0);
      expect(num2(cuota['cargos_neto']), 80);
      expect(cuota['estado'], 'pendiente');
    });

    test('descuento histórico SIN pago_id no se toca al anular', () async {
      final contratoId = await seedContrato();
      final cuotaId = await seedCuota(contratoId: contratoId, monto: 500);
      // Cargo legacy (pre-0115): sin pago_id.
      await seedCargo(cuotaId: cuotaId, tipo: 'descuento_monto', monto: 50);

      final res = await repo.registrarCobro(
        tenantId: tenantId,
        cobradorId: cobradorId,
        prefijoRecibo: prefijo,
        cuotaId: cuotaId,
        montoCordobas: 450,
        moneda: Moneda.nio,
        montoOriginal: 450,
        tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      await repo.anularPago(
          pagoId: res.pagoId, anuladoPorId: cobradorId, motivo: 'error');
      expect(
          await db.getAll(
              'SELECT id FROM cargos_extra WHERE cuota_id = ?', [cuotaId]),
          hasLength(1),
          reason: 'el cargo legacy no nació de este cobro: se preserva');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // registrarCambioFecha — cambio de fecha de pago por días (feature C)
  // ───────────────────────────────────────────────────────────────────────
  group('registrarCambioFecha (cambio de fecha por días)', () {
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    // Fechas RELATIVAS a hoy: el filtro de re-fechado es `periodo >= mes actual`,
    // así que el escenario debe ser determinista corra cuando corra el test.
    final hoy = DateTime.now();
    final mesActual = DateTime(hoy.year, hoy.month, 1);
    final mes1 = DateTime(hoy.year, hoy.month + 1, 1);
    final mes2 = DateTime(hoy.year, hoy.month + 2, 1);
    final mes3 = DateTime(hoy.year, hoy.month + 3, 1);
    // "Pagado hasta" el 15 del mes actual (cuota host pagada).
    final pagadoHasta = DateTime(mesActual.year, mesActual.month, 15);

    Future<({String contratoId, String hostId})> seedEscenario(
        {int? duracionMeses}) async {
      final contratoId =
          await seedContrato(diaPago: 15, duracionMeses: duracionMeses);
      final hostId = await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesActual), fechaVencimiento: ymd(pagadoHasta),
      );
      for (final m in [mes1, mes2, mes3]) {
        await seedCuota(
          contratoId: contratoId, monto: 900,
          periodo: ymd(m),
          fechaVencimiento: ymd(DateTime(m.year, m.month, 15)),
        );
      }
      return (contratoId: contratoId, hostId: hostId);
    }

    test('salto corto (15→30) fijo: NO absorbe, re-fecha futuras, cobra el puente',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 30, precioMensual: 900);
      expect(puente.montoPuente, greaterThan(0));

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 30, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(puente.montoPuente, 0.001));
      expect(num2(pago['vuelto_cordobas']), 0);
      final recibo = await getReciboDePago(res.pagoId);
      expect(recibo['numero_completo'], 'A-00001');

      final host = await getCuota(esc.hostId);
      expect(host['estado'], 'pagada');
      expect(num2(host['cargos_neto']), closeTo(puente.montoPuente, 0.001));
      expect(num2(host['monto_pagado']), closeTo(900 + puente.montoPuente, 0.001));
      expect(num2(host['monto']), 900, reason: 'monto base NUNCA muta');

      final anuladas = await db.getAll(
          "SELECT id FROM cuotas WHERE contrato_id = ? AND estado = 'anulada'",
          [esc.contratoId]);
      expect(anuladas, isEmpty, reason: 'salto corto no absorbe');

      final futuras = await db.getAll(
          "SELECT fecha_vencimiento FROM cuotas WHERE contrato_id = ? AND estado = 'pendiente' ORDER BY date(periodo)",
          [esc.contratoId]);
      expect(futuras, hasLength(3));
      expect(futuras.first['fecha_vencimiento'], ymd(calcularFechaPago(mes1, 30)));

      final total = await db.getAll(
          'SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ?',
          [esc.contratoId]);
      expect((total.first['n'] as num).toInt(), 4, reason: 'sin cuota de cierre');

      final ct = await db
          .getAll('SELECT dia_pago FROM contratos WHERE id = ?', [esc.contratoId]);
      expect((ct.first['dia_pago'] as num).toInt(), 30);
    });

    test('salto que cruza de mes (15→10) fijo: absorbe 1 + agrega cuota de cierre',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 10, precioMensual: 900);

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 10, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );
      expect(res.pagoId, isNotEmpty);

      final mes1Rows = await db.getAll(
          'SELECT estado, motivo_anulacion, anulada_por FROM cuotas WHERE contrato_id = ? AND periodo = ?',
          [esc.contratoId, ymd(mes1)]);
      expect(mes1Rows.first['estado'], 'anulada');
      expect(mes1Rows.first['anulada_por'], cobradorId);
      expect(mes1Rows.first['motivo_anulacion'], isNotNull);

      final mes2Rows = await db.getAll(
          'SELECT fecha_vencimiento FROM cuotas WHERE contrato_id = ? AND periodo = ?',
          [esc.contratoId, ymd(mes2)]);
      expect(mes2Rows.first['fecha_vencimiento'], ymd(calcularFechaPago(mes2, 10)));

      final mes4 = DateTime(mes3.year, mes3.month + 1, 1);
      final cierre = await db.getAll(
          'SELECT monto, estado FROM cuotas WHERE contrato_id = ? AND periodo = ?',
          [esc.contratoId, ymd(mes4)]);
      expect(cierre, hasLength(1), reason: 'cuota de cierre al final');
      expect(cierre.first['estado'], 'pendiente');
      expect(num2(cierre.first['monto']), 900);

      final activas = await db.getAll(
          "SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ? AND estado <> 'anulada' AND tipo_cargo_manual IS NULL",
          [esc.contratoId]);
      expect((activas.first['n'] as num).toInt(), 4,
          reason: 'absorbe 1 + agrega 1 → conteo activo intacto');

      final ct = await db.getAll(
          'SELECT dia_pago, fecha_fin FROM contratos WHERE id = ?',
          [esc.contratoId]);
      expect((ct.first['dia_pago'] as num).toInt(), 10);
      expect(ct.first['fecha_fin'], isNotNull);
    });

    test('indefinido: absorbe pero NO agrega cuota de cierre (fecha_fin queda null)',
        () async {
      final esc = await seedEscenario(duracionMeses: null);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 10, precioMensual: 900);

      await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 10, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente, tasaConversion: 1,
        metodo: MetodoPago.efectivo,
      );

      final anuladas = await db.getAll(
          "SELECT id FROM cuotas WHERE contrato_id = ? AND estado = 'anulada'",
          [esc.contratoId]);
      expect(anuladas, hasLength(1));
      final total = await db.getAll(
          'SELECT COUNT(*) AS n FROM cuotas WHERE contrato_id = ?',
          [esc.contratoId]);
      expect((total.first['n'] as num).toInt(), 4,
          reason: 'indefinido no agrega cierre');
      final ct = await db
          .getAll('SELECT fecha_fin FROM contratos WHERE id = ?', [esc.contratoId]);
      expect(ct.first['fecha_fin'], isNull);
    });

    test('vuelto: si entrega más que el puente, el resto es vuelto en C\$',
        () async {
      final esc = await seedEscenario(duracionMeses: 12);
      final puente = calcularPuenteCambioFecha(
          pagadoHasta: pagadoHasta, diaNuevo: 30, precioMensual: 900);

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: esc.contratoId, diaNuevo: 30, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: puente.montoPuente + 100,
        tasaConversion: 1, metodo: MetodoPago.efectivo,
      );
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(puente.montoPuente, 0.001));
      expect(num2(pago['vuelto_cordobas']), closeTo(100, 0.001));
      // Invariante #3: entregado × tasa ≈ aplicado + vuelto.
      expect(num2(pago['monto_original']) * num2(pago['tasa_conversion']),
          closeTo(num2(pago['monto_cordobas']) + num2(pago['vuelto_cordobas']), 0.01));
    });

    test('guard: cliente NO al día (cuota vencida) lanza y no escribe nada',
        () async {
      final mesPrev = DateTime(hoy.year, hoy.month - 1, 1);
      final contratoId = await seedContrato(diaPago: 15, duracionMeses: 12);
      final hostId = await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesPrev),
        fechaVencimiento: ymd(DateTime(mesPrev.year, mesPrev.month, 15)),
      );
      final ayer = DateTime.now().toUtc().subtract(const Duration(days: 1));
      await seedCuota(
        contratoId: contratoId, monto: 900,
        periodo: ymd(mesActual), fechaVencimiento: ymd(ayer),
      );

      await expectLater(
        repo.registrarCambioFecha(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          contratoId: contratoId, diaNuevo: 30, precioMensual: 900,
          moneda: Moneda.nio, montoOriginal: 1000, tasaConversion: 1,
          metodo: MetodoPago.efectivo,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.getAll('SELECT id FROM pagos'), isEmpty);
      expect(await db.getAll('SELECT id FROM recibos'), isEmpty);
      final host = await getCuota(hostId);
      expect(num2(host['monto_pagado']), 900);
    });

    test('fix #4: pagadoHasta usa el día nominal (periodo+dia_pago), no la venc shifteada',
        () async {
      // Host con fecha_vencimiento DISTINTA del día nominal (simula el ajuste
      // domingo→lunes u otra divergencia): dia_pago=20 pero la venc quedó en el
      // día 10. pagadoHasta debe salir del nominal (20), no de la venc (10).
      final contratoId = await seedContrato(diaPago: 20, duracionMeses: null);
      await seedCuota(
        contratoId: contratoId, monto: 900, estado: 'pagada', montoPagado: 900,
        periodo: ymd(mesActual),
        fechaVencimiento: ymd(DateTime(mesActual.year, mesActual.month, 10)),
      );
      for (final m in [mes1, mes2]) {
        await seedCuota(
          contratoId: contratoId, monto: 900,
          periodo: ymd(m),
          fechaVencimiento: ymd(DateTime(m.year, m.month, 20)),
        );
      }

      // Nominal: pagadoHasta=20 del mes actual → al 25 = 5 días de puente.
      // (Usar la venc shifteada=10 daría ~15 días → un puente ~3× mayor.)
      final esperado = calcularPuenteCambioFecha(
          pagadoHasta: DateTime(mesActual.year, mesActual.month, 20),
          diaNuevo: 25, precioMensual: 900);
      expect(esperado.diasPuente, 5);

      final res = await repo.registrarCambioFecha(
        tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
        contratoId: contratoId, diaNuevo: 25, precioMensual: 900,
        moneda: Moneda.nio, montoOriginal: esperado.montoPuente,
        tasaConversion: 1, metodo: MetodoPago.efectivo,
      );
      final pago = await getPago(res.pagoId);
      expect(num2(pago['monto_cordobas']), closeTo(esperado.montoPuente, 0.01),
          reason: 'puente de 5 días (nominal), no ~15 días de la venc shifteada');
    });

    test('fix #5: cambiar al MISMO día de pago lanza y no escribe nada', () async {
      final esc = await seedEscenario(duracionMeses: 12); // dia_pago = 15
      await expectLater(
        repo.registrarCambioFecha(
          tenantId: tenantId, cobradorId: cobradorId, prefijoRecibo: prefijo,
          contratoId: esc.contratoId, diaNuevo: 15, precioMensual: 900,
          moneda: Moneda.nio, montoOriginal: 1000, tasaConversion: 1,
          metodo: MetodoPago.efectivo,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.getAll('SELECT id FROM pagos'), isEmpty);
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
    p.join(root, 'powersync_x64.dll'), // Windows (powersync_core 1.18, arch-suffix)
    p.join(root, 'powersync.dll'), // Windows (nombre de docs / sin sufijo)
    p.join(root, 'powersync_aarch64.dll'), // Windows ARM
    p.join(root, 'libpowersync_x64.so'),
    p.join(root, 'libpowersync_aarch64.so'),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
