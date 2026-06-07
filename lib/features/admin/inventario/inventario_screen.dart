import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_cambios_widget.dart';

/// Inventario — módulo opcional (gateado por tenant_modulos 'inventario').
/// Pestañas: Productos (catálogo, 2A) · Ubicaciones · Proveedores (2B).
/// Recepciones/movimientos/stock llegan en 2C.
class InventarioScreen extends StatelessWidget {
  const InventarioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(
        children: const [
          TabBar(isScrollable: true, tabs: [
            Tab(text: 'Existencias'),
            Tab(text: 'Equipos'),
            Tab(text: 'Productos'),
            Tab(text: 'Ubicaciones'),
            Tab(text: 'Proveedores'),
          ]),
          Expanded(
            child: TabBarView(children: [
              _ExistenciasTab(),
              _EquiposTab(),
              _ProductosTab(),
              _UbicacionesTab(),
              _ProveedoresTab(),
            ]),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// PRODUCTOS
// ===========================================================================
class _ProductosTab extends ConsumerStatefulWidget {
  const _ProductosTab();
  @override
  ConsumerState<_ProductosTab> createState() => _ProductosTabState();
}

class _ProductosTabState extends ConsumerState<_ProductosTab> {
  late final Stream<List<Map<String, dynamic>>> _productos;

  @override
  void initState() {
    super.initState();
    _productos = ps.db.watch('''
      SELECT p.*, c.nombre AS categoria_nombre
        FROM inv_productos p
   LEFT JOIN inv_categorias c ON c.id = p.categoria_id
       WHERE p.activo = 1
       ORDER BY p.nombre
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Producto'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _productos,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.inventory_2_outlined,
              titulo: 'Sin productos',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primero'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = rows[i];
              final serializado = (p['es_serializado'] as int? ?? 0) == 1;
              final cat = p['categoria_nombre'] as String?;
              final partes = [
                if (cat != null && cat.isNotEmpty) cat,
                serializado ? 'serializado' : 'granel (${p['unidad']})',
              ];
              return ListTile(
                leading: Icon(serializado ? Icons.qr_code_2 : Icons.straighten,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(p['nombre'] as String),
                subtitle: Text(partes.join(' · ')),
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: p),
                  onHistorial: () => _showHistorialInv(context, 'inv_productos',
                      p['id'] as String, 'Historial del producto'),
                  onEliminar: () => _eliminar(context, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<_ProductoData>(
      context: context,
      builder: (_) => _ProductoDialog(tenantId: tenantId, existente: existente),
    );
    if (res == null) return;
    try {
      if (existente == null) {
        await ps.db.execute(
          '''INSERT INTO inv_productos
             (id, tenant_id, categoria_id, codigo, nombre, es_serializado,
              unidad, maneja_decimal, costo_promedio, activo, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?)''',
          [
            const Uuid().v4(), tenantId, res.categoriaId, res.codigo, res.nombre,
            res.esSerializado ? 1 : 0, res.unidad, res.manejaDecimal ? 1 : 0,
            DateTime.now().toIso8601String(),
          ],
        );
      } else {
        // Guarda: no cambiar el TIPO (serializado↔granel) de un producto que ya
        // tiene seriales o movimientos → dejaría seriales huérfanos y el stock
        // (que se deriva distinto por tipo) incoherente.
        final cambiaTipo = res.esSerializado !=
            ((existente['es_serializado'] as int? ?? 0) == 1);
        if (cambiaTipo) {
          final enUso = await _contar(
            'SELECT (SELECT COUNT(*) FROM inv_seriales WHERE producto_id = ?)'
            ' + (SELECT COUNT(*) FROM inv_movimientos WHERE producto_id = ?) AS n',
            [existente['id'], existente['id']],
          );
          if (!context.mounted) return;
          if (enUso > 0) {
            _snack(context,
                'No se puede cambiar serializado/granel: el producto ya tiene movimientos o equipos.');
            return;
          }
        }
        await ps.db.execute(
          '''UPDATE inv_productos
                SET categoria_id = ?, codigo = ?, nombre = ?, es_serializado = ?,
                    unidad = ?, maneja_decimal = ?
              WHERE id = ?''',
          [
            res.categoriaId, res.codigo, res.nombre, res.esSerializado ? 1 : 0,
            res.unidad, res.manejaDecimal ? 1 : 0, existente['id'],
          ],
        );
      }
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> p) async {
    final id = p['id'] as String;
    // Guarda de "en uso": no borrar si tiene equipos serializados o movimientos
    // (el ledger es append-only; borrar el producto huerfanizaría su historial).
    final enSeriales = await _contar(
        'SELECT COUNT(*) AS n FROM inv_seriales WHERE producto_id = ?', [id]);
    final enMovs = await _contar(
        'SELECT COUNT(*) AS n FROM inv_movimientos WHERE producto_id = ?', [id]);
    if (!context.mounted) return;
    if (enSeriales + enMovs > 0) {
      _snack(context,
          'No se puede eliminar "${p['nombre']}": tiene equipos o movimientos asociados (${enSeriales + enMovs}).');
      return;
    }
    if (!await _confirmar(context, '"${p['nombre']}"')) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_productos',
      id: id,
      countSql: 'SELECT (SELECT COUNT(*) FROM inv_seriales WHERE producto_id = ?)'
          ' + (SELECT COUNT(*) FROM inv_movimientos WHERE producto_id = ?) AS n',
      countParams: [id, id],
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// UBICACIONES
// ===========================================================================
const _tiposUbicacion = {
  'central': 'Bodega central',
  'bodega': 'Bodega',
  'vehiculo': 'Vehículo',
  'tecnico': 'Custodia de técnico',
};

class _UbicacionesTab extends ConsumerStatefulWidget {
  const _UbicacionesTab();
  @override
  ConsumerState<_UbicacionesTab> createState() => _UbicacionesTabState();
}

class _UbicacionesTabState extends ConsumerState<_UbicacionesTab> {
  late final Stream<List<Map<String, dynamic>>> _ubicaciones;

  @override
  void initState() {
    super.initState();
    _ubicaciones = ps.db.watch(
        'SELECT * FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Ubicación'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _ubicaciones,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.warehouse_outlined,
              titulo: 'Sin ubicaciones',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primera'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final u = rows[i];
              return ListTile(
                leading: Icon(Icons.warehouse,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(u['nombre'] as String),
                subtitle: Text(_tiposUbicacion[u['tipo']] ?? u['tipo'] as String),
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: u),
                  onHistorial: () => _showHistorialInv(context,
                      'inv_ubicaciones', u['id'] as String,
                      'Historial de la ubicación'),
                  onEliminar: () => _eliminar(context, u),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<({String nombre, String tipo})>(
      context: context,
      builder: (_) => _UbicacionDialog(existente: existente),
    );
    if (res == null) return;
    try {
      if (existente == null) {
        await ps.db.execute(
          'INSERT INTO inv_ubicaciones (id, tenant_id, nombre, tipo, activa, created_at) VALUES (?, ?, ?, ?, 1, ?)',
          [const Uuid().v4(), tenantId, res.nombre, res.tipo,
            DateTime.now().toIso8601String()],
        );
      } else {
        await ps.db.execute(
          'UPDATE inv_ubicaciones SET nombre = ?, tipo = ? WHERE id = ?',
          [res.nombre, res.tipo, existente['id']],
        );
      }
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> u) async {
    final id = u['id'] as String;
    // Guarda de "en uso": no borrar si hay equipos o movimientos en esta
    // ubicación (su FK es ON DELETE SET NULL → borrar nulearía la referencia).
    final enSeriales = await _contar(
        'SELECT COUNT(*) AS n FROM inv_seriales WHERE ubicacion_id = ?', [id]);
    final enMovs = await _contar(
        'SELECT COUNT(*) AS n FROM inv_movimientos WHERE ubicacion_origen_id = ? OR ubicacion_destino_id = ?',
        [id, id]);
    if (!context.mounted) return;
    if (enSeriales + enMovs > 0) {
      _snack(context,
          'No se puede eliminar "${u['nombre']}": tiene equipos o movimientos asociados (${enSeriales + enMovs}).');
      return;
    }
    if (!await _confirmar(context, '"${u['nombre']}"')) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_ubicaciones',
      id: id,
      countSql:
          'SELECT (SELECT COUNT(*) FROM inv_seriales WHERE ubicacion_id = ?)'
          ' + (SELECT COUNT(*) FROM inv_movimientos'
          ' WHERE ubicacion_origen_id = ? OR ubicacion_destino_id = ?) AS n',
      countParams: [id, id, id],
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// PROVEEDORES
// ===========================================================================
class _ProveedoresTab extends ConsumerStatefulWidget {
  const _ProveedoresTab();
  @override
  ConsumerState<_ProveedoresTab> createState() => _ProveedoresTabState();
}

class _ProveedoresTabState extends ConsumerState<_ProveedoresTab> {
  late final Stream<List<Map<String, dynamic>>> _proveedores;

  @override
  void initState() {
    super.initState();
    _proveedores = ps.db.watch(
        'SELECT * FROM inv_proveedores WHERE activo = 1 ORDER BY nombre');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Proveedor'),
        onPressed: () => _crear(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _proveedores,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.local_shipping_outlined,
              titulo: 'Sin proveedores',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primero'),
                onPressed: () => _crear(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = rows[i];
              final tel = p['telefono'] as String?;
              return ListTile(
                leading: Icon(Icons.local_shipping,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(p['nombre'] as String),
                subtitle: tel != null && tel.isNotEmpty ? Text(tel) : null,
                trailing: _InvRowMenu(
                  onEditar: () => _crear(context, existente: p),
                  onHistorial: () => _showHistorialInv(context,
                      'inv_proveedores', p['id'] as String,
                      'Historial del proveedor'),
                  onEliminar: () => _eliminar(context, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crear(BuildContext context,
      {Map<String, dynamic>? existente}) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final res = await showDialog<({String nombre, String? telefono, String? notas})>(
      context: context,
      builder: (_) => _ProveedorDialog(existente: existente),
    );
    if (res == null) return;
    try {
      if (existente == null) {
        await ps.db.execute(
          'INSERT INTO inv_proveedores (id, tenant_id, nombre, telefono, notas, activo, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)',
          [const Uuid().v4(), tenantId, res.nombre, res.telefono, res.notas,
            DateTime.now().toIso8601String()],
        );
      } else {
        await ps.db.execute(
          'UPDATE inv_proveedores SET nombre = ?, telefono = ?, notas = ? WHERE id = ?',
          [res.nombre, res.telefono, res.notas, existente['id']],
        );
      }
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  Future<void> _eliminar(BuildContext context, Map<String, dynamic> p) async {
    final id = p['id'] as String;
    // Guarda de "en uso": no borrar un proveedor con movimientos (su FK es
    // ON DELETE SET NULL → borrarlo perdería la procedencia del ingreso).
    final enMovs = await _contar(
        'SELECT COUNT(*) AS n FROM inv_movimientos WHERE proveedor_id = ?', [id]);
    if (!context.mounted) return;
    if (enMovs > 0) {
      _snack(context,
          'No se puede eliminar "${p['nombre']}": tiene movimientos asociados ($enMovs).');
      return;
    }
    if (!await _confirmar(context, '"${p['nombre']}"')) return;
    final err = await _borrarSiLibre(
      tabla: 'inv_proveedores',
      id: id,
      countSql: 'SELECT COUNT(*) AS n FROM inv_movimientos WHERE proveedor_id = ?',
      countParams: [id],
    );
    if (!context.mounted) return;
    if (err != null) _snack(context, err);
  }
}

// ===========================================================================
// EXISTENCIAS (stock derivado del ledger) + INGRESO
// ===========================================================================
class _ExistenciasTab extends ConsumerStatefulWidget {
  const _ExistenciasTab();
  @override
  ConsumerState<_ExistenciasTab> createState() => _ExistenciasTabState();
}

class _ExistenciasTabState extends ConsumerState<_ExistenciasTab> {
  late final Stream<List<Map<String, dynamic>>> _stock;

  @override
  void initState() {
    super.initState();
    // Stock por producto. Dos derivaciones según el tipo:
    //  · Serializado: COUNT de seriales en estado 'en_stock'. El estado del
    //    serial es la verdad física de la unidad → evita que el ledger y el
    //    estado diverjan (un movimiento con ubicación NULL o una doble
    //    asignación NO pueden inflar/desinflar el stock).
    //  · Granel: Σ(cantidad con destino) − Σ(cantidad con origen) del ledger.
    //    Las transferencias internas netean a 0.
    _stock = ps.db.watch('''
      SELECT p.id, p.nombre, p.unidad, p.es_serializado, p.costo_promedio,
             CASE WHEN p.es_serializado = 1 THEN
               COALESCE((
                 SELECT COUNT(*) FROM inv_seriales s
                  WHERE s.producto_id = p.id AND s.estado = 'en_stock'
               ), 0)
             ELSE
               COALESCE((
                 SELECT SUM(CASE WHEN m.ubicacion_destino_id IS NOT NULL THEN m.cantidad ELSE 0 END)
                      - SUM(CASE WHEN m.ubicacion_origen_id  IS NOT NULL THEN m.cantidad ELSE 0 END)
                   FROM inv_movimientos m WHERE m.producto_id = p.id
               ), 0)
             END AS stock
        FROM inv_productos p
       WHERE p.activo = 1
       ORDER BY p.nombre
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'inv_mov',
            tooltip: 'Egreso / Ajuste / Transferencia',
            onPressed: () => _movimiento(context),
            child: const Icon(Icons.swap_horiz),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'inv_ingreso',
            icon: const Icon(Icons.add_box),
            label: const Text('Ingreso'),
            onPressed: () => _ingreso(context),
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stock,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.warehouse_outlined,
              titulo: 'Sin existencias',
              descripcion: 'Cargá productos y registrá un ingreso.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              final stock = (r['stock'] as num?) ?? 0;
              final serial = (r['es_serializado'] as int? ?? 0) == 1;
              final unidad = serial ? 'u' : (r['unidad'] as String? ?? 'u');
              final bajo = stock <= 0;
              final costo = (r['costo_promedio'] as num?) ?? 0;
              final valor = stock > 0 ? stock * costo : 0;
              return ListTile(
                leading: Icon(Icons.inventory,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(r['nombre'] as String),
                subtitle: costo > 0
                    ? Text(
                        'Costo prom. ${Fmt.cordobas(costo)}'
                        '${valor > 0 ? ' · Valor ${Fmt.cordobas(valor)}' : ''}',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            fontSize: 12),
                      )
                    : null,
                onTap: () => _verStockPorUbicacion(context, r),
                trailing: Text(
                  '${_fmtCant(stock)} $unidad',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: bajo
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _ingreso(BuildContext context) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final res = await showDialog<_IngresoData>(
      context: context,
      builder: (_) => const _IngresoDialog(),
    );
    if (res == null) return;
    final now = DateTime.now().toIso8601String();

    // Pre-check de unicidad de seriales (local). El UNIQUE(tenant,serial) del
    // server es la red dura si otro device creó el mismo serial sin sincronizar.
    if (res.esSerializado) {
      for (final s in res.seriales) {
        final dup = await ps.db.getAll(
          'SELECT 1 FROM inv_seriales WHERE tenant_id = ? AND serial = ? LIMIT 1',
          [tenantId, s.serial],
        );
        if (dup.isNotEmpty) {
          _snack(context, 'El serial "${s.serial}" ya existe.');
          return;
        }
      }
    }

    const movSql = '''INSERT INTO inv_movimientos
         (id, tenant_id, tipo, producto_id, serial_id, cantidad,
          ubicacion_destino_id, proveedor_id, numero_factura, costo_unitario,
          hecho_por, ocurrido_en, created_at)
         VALUES (?, ?, 'ingreso', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''';

    try {
      // Atómico: cada serial + su movimiento (y todo el lote) viven o caen
      // juntos (patrón writeTransaction del repo, igual que el cobro).
      await ps.db.writeTransaction((tx) async {
        // Costo promedio ponderado: capturamos stock y promedio ANTES del
        // ingreso (solo si vino un costo unitario; sin costo no tocamos el avg).
        num stockPrevio = 0;
        double avgPrevio = 0;
        if (res.costoUnitario != null) {
          final stockSql = res.esSerializado
              ? "SELECT COUNT(*) AS s FROM inv_seriales WHERE producto_id = ? AND estado = 'en_stock'"
              : '''SELECT COALESCE(SUM(CASE WHEN ubicacion_destino_id IS NOT NULL THEN cantidad ELSE 0 END)
                                - SUM(CASE WHEN ubicacion_origen_id  IS NOT NULL THEN cantidad ELSE 0 END), 0) AS s
                     FROM inv_movimientos WHERE producto_id = ?''';
          final sr = await tx.getAll(stockSql, [res.productoId]);
          stockPrevio = (sr.first['s'] as num?) ?? 0;
          final pr = await tx.getAll(
              'SELECT costo_promedio FROM inv_productos WHERE id = ?',
              [res.productoId]);
          avgPrevio = (pr.first['costo_promedio'] as num?)?.toDouble() ?? 0;
        }

        if (res.esSerializado) {
          for (final s in res.seriales) {
            final serialId = const Uuid().v4();
            await tx.execute(
              '''INSERT INTO inv_seriales
                 (id, tenant_id, producto_id, serial, mac, estado, ubicacion_id,
                  costo_ingreso, created_at)
                 VALUES (?, ?, ?, ?, ?, 'en_stock', ?, ?, ?)''',
              [serialId, tenantId, res.productoId, s.serial, s.mac,
                res.ubicacionDestinoId, res.costoUnitario, now],
            );
            await tx.execute(movSql, [
              const Uuid().v4(), tenantId, res.productoId, serialId, 1,
              res.ubicacionDestinoId, res.proveedorId, res.numeroFactura,
              res.costoUnitario, hechoPor, now, now,
            ]);
          }
        } else {
          await tx.execute(movSql, [
            const Uuid().v4(), tenantId, res.productoId, null, res.cantidad,
            res.ubicacionDestinoId, res.proveedorId, res.numeroFactura,
            res.costoUnitario, hechoPor, now, now,
          ]);
        }

        // Promedio ponderado móvil: (stock·avg + cant·costo) / (stock + cant).
        // Si no había stock (o era negativo) arranca del costo de este ingreso.
        if (res.costoUnitario != null) {
          final n = res.esSerializado
              ? res.seriales.length.toDouble()
              : res.cantidad;
          final nuevoAvg = stockPrevio <= 0
              ? res.costoUnitario!
              : (stockPrevio * avgPrevio + n * res.costoUnitario!) /
                  (stockPrevio + n);
          await tx.execute(
              'UPDATE inv_productos SET costo_promedio = ? WHERE id = ?',
              [nuevoAvg, res.productoId]);
        }
      });
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  // Egreso / ajuste / transferencia de productos a GRANEL (los serializados se
  // mueven por equipo en la pestaña Equipos). Un solo movimiento en el ledger.
  Future<void> _movimiento(BuildContext context) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    // Estado vacío (M5): sin productos a granel o sin ubicaciones el diálogo es
    // inusable; avisamos en vez de abrir un form imposible de completar.
    final granel = await _contar(
        'SELECT COUNT(*) AS n FROM inv_productos WHERE activo = 1 AND es_serializado = 0',
        const []);
    final ubis = await _contar(
        'SELECT COUNT(*) AS n FROM inv_ubicaciones WHERE activa = 1', const []);
    if (!context.mounted) return;
    if (granel == 0) {
      _snack(context,
          'No hay productos a granel. Los equipos serializados se mueven desde la pestaña Equipos.');
      return;
    }
    if (ubis == 0) {
      _snack(context, 'No hay ubicaciones. Creá una primero.');
      return;
    }
    final res = await showDialog<_MovimientoData>(
      context: context,
      builder: (_) => const _MovimientoDialog(),
    );
    if (res == null || !context.mounted) return;
    final now = DateTime.now().toIso8601String();

    // Mapear el tipo al par origen/destino que entiende la fórmula de stock.
    String? origen;
    String? destino;
    if (res.tipo == 'egreso') {
      origen = res.ubicacionOrigenId;
    } else if (res.tipo == 'transferencia') {
      origen = res.ubicacionOrigenId;
      destino = res.ubicacionDestinoId;
    } else {
      // ajuste: sumar → entra (destino +); restar → sale (origen −).
      if (res.sumar) {
        destino = res.ubicacionId;
      } else {
        origen = res.ubicacionId;
      }
    }

    try {
      await ps.db.execute(
        '''INSERT INTO inv_movimientos
           (id, tenant_id, tipo, producto_id, cantidad, ubicacion_origen_id,
            ubicacion_destino_id, motivo, hecho_por, ocurrido_en, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          const Uuid().v4(), tenantId, res.tipo, res.productoId, res.cantidad,
          origen, destino, res.motivo, hechoPor, now, now,
        ],
      );
      // M1: mostrar el stock resultante (y avisar si quedó negativo). Stock de
      // granel = Σdestino − Σorigen del ledger.
      final stockRows = await ps.db.getAll(
        '''SELECT p.nombre,
                  COALESCE((
                    SELECT SUM(CASE WHEN ubicacion_destino_id IS NOT NULL THEN cantidad ELSE 0 END)
                         - SUM(CASE WHEN ubicacion_origen_id  IS NOT NULL THEN cantidad ELSE 0 END)
                      FROM inv_movimientos WHERE producto_id = p.id), 0) AS stock
             FROM inv_productos p WHERE p.id = ?''',
        [res.productoId],
      );
      if (!context.mounted) return;
      final nombre =
          stockRows.isNotEmpty ? stockRows.first['nombre'] as String? : null;
      final num stock =
          stockRows.isNotEmpty ? (stockRows.first['stock'] as num?) ?? 0 : 0;
      final etq = nombre != null ? ' de $nombre' : '';
      _snack(
        context,
        stock < 0
            ? '⚠ Movimiento registrado. Stock$etq: ${_fmtCant(stock)} (negativo)'
            : 'Movimiento registrado. Stock$etq: ${_fmtCant(stock)}',
      );
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  // Desglose del stock de un producto POR UBICACIÓN (M2). Serializado = conteo
  // de seriales en_stock por ubicación; granel = Σdestino−Σorigen por ubicación.
  void _verStockPorUbicacion(BuildContext context, Map<String, dynamic> p) {
    final serial = (p['es_serializado'] as int? ?? 0) == 1;
    final sql = serial
        ? '''SELECT u.nombre, COUNT(s.id) AS n
               FROM inv_ubicaciones u
          LEFT JOIN inv_seriales s ON s.ubicacion_id = u.id
                 AND s.producto_id = ? AND s.estado = 'en_stock'
              WHERE u.activa = 1
              GROUP BY u.id, u.nombre
             HAVING COUNT(s.id) > 0
              ORDER BY u.nombre'''
        : '''SELECT u.nombre,
                    COALESCE((
                      SELECT SUM(CASE WHEN m.ubicacion_destino_id = u.id THEN m.cantidad ELSE 0 END)
                           - SUM(CASE WHEN m.ubicacion_origen_id  = u.id THEN m.cantidad ELSE 0 END)
                        FROM inv_movimientos m WHERE m.producto_id = ?), 0) AS n
               FROM inv_ubicaciones u
              WHERE u.activa = 1
              ORDER BY u.nombre''';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _StockPorUbicacionSheet(
        titulo: p['nombre'] as String,
        sql: sql,
        productoId: p['id'] as String,
        unidad: serial ? 'u' : (p['unidad'] as String? ?? 'u'),
      ),
    );
  }
}

class _IngresoData {
  const _IngresoData({
    required this.productoId,
    required this.esSerializado,
    required this.ubicacionDestinoId,
    required this.proveedorId,
    required this.numeroFactura,
    required this.costoUnitario,
    required this.cantidad,
    required this.seriales,
  });
  final String productoId;
  final bool esSerializado;
  final String ubicacionDestinoId;
  final String? proveedorId;
  final String? numeroFactura;
  final double? costoUnitario;
  final double cantidad;
  // Cada serial con su MAC opcional (formato "serial, MAC" por línea).
  final List<({String serial, String? mac})> seriales;
}

class _MovimientoData {
  const _MovimientoData({
    required this.tipo,
    required this.productoId,
    required this.cantidad,
    this.ubicacionOrigenId,
    this.ubicacionDestinoId,
    this.ubicacionId,
    this.sumar = false,
    this.motivo,
  });
  final String tipo; // 'egreso' | 'ajuste' | 'transferencia'
  final String productoId;
  final double cantidad;
  final String? ubicacionOrigenId; // egreso, transferencia
  final String? ubicacionDestinoId; // transferencia
  final String? ubicacionId; // ajuste
  final bool sumar; // ajuste: true=suma (+), false=resta (−)
  final String? motivo;
}

/// Movimiento de granel: egreso (−), ajuste (±) o transferencia (origen→destino).
class _MovimientoDialog extends StatefulWidget {
  const _MovimientoDialog();
  @override
  State<_MovimientoDialog> createState() => _MovimientoDialogState();
}

class _MovimientoDialogState extends State<_MovimientoDialog> {
  String _tipo = 'egreso';
  String? _productoId;
  String? _origenId;
  String? _destinoId;
  String? _ajusteUbiId;
  bool _sumar = false; // por defecto restar (corrección a la baja)
  final _cantidad = TextEditingController(text: '1');
  final _motivo = TextEditingController();

  // Stock por ubicación del producto elegido (M2): para egreso/transferencia el
  // origen se restringe a ubicaciones con stock > 0, mostrando la cantidad.
  List<Map<String, dynamic>> _stockPorUbi = const [];
  bool _cargandoStock = false;

  late final Stream<List<Map<String, dynamic>>> _productos;
  late final Stream<List<Map<String, dynamic>>> _ubicaciones;

  static const _tipos = {
    'egreso': 'Egreso (salida)',
    'ajuste': 'Ajuste (corrección)',
    'transferencia': 'Transferencia',
  };

  @override
  void initState() {
    super.initState();
    // Solo granel: los serializados se mueven por equipo (asignar/baja/transferir).
    _productos = ps.db.watch(
        'SELECT id, nombre FROM inv_productos WHERE activo = 1 AND es_serializado = 0 ORDER BY nombre');
    _ubicaciones = ps.db.watch(
        'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  }

  @override
  void dispose() {
    _cantidad.dispose();
    _motivo.dispose();
    super.dispose();
  }

  // Recarga el stock por ubicación del producto (solo egreso/transferencia, que
  // salen de un origen concreto). El ajuste no lo necesita (corrige cualquier
  // ubicación). Limpia el origen elegido si dejó de tener stock.
  Future<void> _reloadStock() async {
    final pid = _productoId;
    final tipo = _tipo;
    if (pid == null || (tipo != 'egreso' && tipo != 'transferencia')) {
      if (mounted) setState(() => _stockPorUbi = const []);
      return;
    }
    setState(() => _cargandoStock = true);
    final rows = await ps.db.getAll('''
      SELECT u.id, u.nombre,
             COALESCE((
               SELECT SUM(CASE WHEN m.ubicacion_destino_id = u.id THEN m.cantidad ELSE 0 END)
                    - SUM(CASE WHEN m.ubicacion_origen_id  = u.id THEN m.cantidad ELSE 0 END)
                 FROM inv_movimientos m WHERE m.producto_id = ?), 0) AS stock
        FROM inv_ubicaciones u WHERE u.activa = 1 ORDER BY u.nombre
    ''', [pid]);
    // Si el producto/tipo cambió mientras cargaba, descartamos este resultado
    // (el call más nuevo maneja el flag de carga y su propio resultado).
    if (!mounted || pid != _productoId || tipo != _tipo) return;
    setState(() {
      _stockPorUbi = rows
          .map((r) => {
                'id': r['id'],
                'nombre': r['nombre'],
                'stock': (r['stock'] as num?) ?? 0,
              })
          .where((r) => (r['stock'] as num) > 0)
          .toList();
      if (_origenId != null &&
          !_stockPorUbi.any((r) => r['id'] == _origenId)) {
        _origenId = null;
      }
      _cargandoStock = false;
    });
  }

  // Dropdown de origen para egreso/transferencia: solo ubicaciones con stock,
  // con la cantidad disponible al lado.
  Widget _origenStockDropdown() {
    if (_cargandoStock) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    if (_productoId == null || _stockPorUbi.isEmpty) {
      return InputDecorator(
        decoration: const InputDecoration(labelText: 'Ubicación origen'),
        child: Text(
          _productoId == null
              ? 'Elegí un producto'
              : 'Sin stock en ninguna ubicación',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return DropdownButtonFormField<String?>(
      value: _stockPorUbi.any((r) => r['id'] == _origenId) ? _origenId : null,
      decoration: const InputDecoration(labelText: 'Ubicación origen (con stock)'),
      isExpanded: true,
      onChanged: (v) => setState(() => _origenId = v),
      items: _stockPorUbi
          .map((r) => DropdownMenuItem(
                value: r['id'] as String,
                child: Text('${r['nombre']} (${_fmtCant(r['stock'] as num)})'),
              ))
          .toList(),
    );
  }

  Widget _ubiDropdown(
      String label, String? value, ValueChanged<String?> onChanged) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _ubicaciones,
      initialData: const [],
      builder: (context, snap) {
        final rows = snap.data!;
        final exists = value == null || rows.any((r) => r['id'] == value);
        return DropdownButtonFormField<String?>(
          value: exists ? value : null,
          decoration: InputDecoration(labelText: label),
          isExpanded: true,
          onChanged: onChanged,
          items: rows
              .map((r) => DropdownMenuItem(
                    value: r['id'] as String,
                    child: Text(r['nombre'] as String),
                  ))
              .toList(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Movimiento de stock'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _tipo,
              decoration: const InputDecoration(labelText: 'Tipo'),
              isExpanded: true,
              onChanged: (v) {
                setState(() => _tipo = v ?? 'egreso');
                _reloadStock();
              },
              items: _tipos.entries
                  .map((e) =>
                      DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _productos,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data!;
                final exists = _productoId == null ||
                    rows.any((r) => r['id'] == _productoId);
                return DropdownButtonFormField<String?>(
                  value: exists ? _productoId : null,
                  decoration:
                      const InputDecoration(labelText: 'Producto (granel)'),
                  isExpanded: true,
                  onChanged: (v) {
                    setState(() => _productoId = v);
                    _reloadStock();
                  },
                  items: rows
                      .map((r) => DropdownMenuItem(
                            value: r['id'] as String,
                            child: Text(r['nombre'] as String),
                          ))
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 12),
            if (_tipo == 'egreso') _origenStockDropdown(),
            if (_tipo == 'transferencia') ...[
              _origenStockDropdown(),
              const SizedBox(height: 12),
              _ubiDropdown('Ubicación destino', _destinoId,
                  (v) => setState(() => _destinoId = v)),
            ],
            if (_tipo == 'ajuste') ...[
              _ubiDropdown('Ubicación', _ajusteUbiId,
                  (v) => setState(() => _ajusteUbiId = v)),
              const SizedBox(height: 12),
              DropdownButtonFormField<bool>(
                value: _sumar,
                decoration: const InputDecoration(labelText: 'Operación'),
                onChanged: (v) => setState(() => _sumar = v ?? false),
                items: const [
                  DropdownMenuItem(value: false, child: Text('Restar (−)')),
                  DropdownMenuItem(value: true, child: Text('Sumar (+)')),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _cantidad,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Cantidad'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _motivo,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _tipo == 'ajuste'
                    ? 'Motivo (obligatorio)'
                    : 'Motivo (opcional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Registrar')),
      ],
    );
  }

  Future<void> _submit() async {
    if (_productoId == null) {
      _snack(context, 'Elegí un producto.');
      return;
    }
    final cant = double.tryParse(_cantidad.text.trim()) ?? 0;
    if (cant <= 0) {
      _snack(context, 'Cantidad inválida.');
      return;
    }
    final motivo = _motivo.text.trim();
    final _MovimientoData data;
    if (_tipo == 'egreso') {
      if (_origenId == null) {
        _snack(context, 'Elegí la ubicación origen.');
        return;
      }
      data = _MovimientoData(
        tipo: 'egreso',
        productoId: _productoId!,
        cantidad: cant,
        ubicacionOrigenId: _origenId,
        motivo: motivo.isEmpty ? null : motivo,
      );
    } else if (_tipo == 'transferencia') {
      if (_origenId == null || _destinoId == null) {
        _snack(context, 'Elegí origen y destino.');
        return;
      }
      if (_origenId == _destinoId) {
        _snack(context, 'Origen y destino deben ser distintos.');
        return;
      }
      data = _MovimientoData(
        tipo: 'transferencia',
        productoId: _productoId!,
        cantidad: cant,
        ubicacionOrigenId: _origenId,
        ubicacionDestinoId: _destinoId,
        motivo: motivo.isEmpty ? null : motivo,
      );
    } else {
      if (_ajusteUbiId == null) {
        _snack(context, 'Elegí la ubicación.');
        return;
      }
      if (motivo.isEmpty) {
        _snack(context, 'El ajuste requiere un motivo.');
        return;
      }
      data = _MovimientoData(
        tipo: 'ajuste',
        productoId: _productoId!,
        cantidad: cant,
        ubicacionId: _ajusteUbiId,
        sumar: _sumar,
        motivo: motivo,
      );
    }

    // Overselling (M2): egreso/transferencia que saca MÁS de lo disponible en la
    // ubicación origen → aviso suave (el modelo permite stock negativo, pero lo
    // señalamos para no romper una ubicación en silencio).
    if (_tipo == 'egreso' || _tipo == 'transferencia') {
      final disp = (_stockPorUbi.firstWhere(
            (r) => r['id'] == _origenId,
            orElse: () => const <String, dynamic>{},
          )['stock'] as num?) ??
          0;
      if (cant > disp) {
        final seguir = await _confirmarAccion(
          context,
          titulo: 'Más que el stock disponible',
          mensaje: 'En esa ubicación hay ${_fmtCant(disp)} y vas a sacar '
              '${_fmtCant(cant)}. Quedará en negativo. ¿Seguir?',
          confirmar: 'Sacar igual',
        );
        if (!seguir || !mounted) return;
      }
    }

    if (!mounted) return;
    Navigator.pop(context, data);
  }
}

class _IngresoDialog extends StatefulWidget {
  const _IngresoDialog();
  @override
  State<_IngresoDialog> createState() => _IngresoDialogState();
}

class _IngresoDialogState extends State<_IngresoDialog> {
  String? _productoId;
  bool _serializado = false;
  String? _ubicacionId;
  String? _proveedorId;
  final _factura = TextEditingController();
  final _costo = TextEditingController();
  final _cantidad = TextEditingController(text: '1');
  final _seriales = TextEditingController();

  late final Stream<List<Map<String, dynamic>>> _productos;
  late final Stream<List<Map<String, dynamic>>> _ubicaciones;
  late final Stream<List<Map<String, dynamic>>> _proveedores;

  @override
  void initState() {
    super.initState();
    _productos = ps.db.watch(
        'SELECT id, nombre, es_serializado FROM inv_productos WHERE activo = 1 ORDER BY nombre');
    _ubicaciones = ps.db.watch(
        'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
    _proveedores = ps.db.watch(
        'SELECT id, nombre FROM inv_proveedores WHERE activo = 1 ORDER BY nombre');
  }

  @override
  void dispose() {
    _factura.dispose();
    _costo.dispose();
    _cantidad.dispose();
    _seriales.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ingreso de mercadería'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Producto (define si es serializado o granel).
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _productos,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data!;
                final exists =
                    _productoId == null || rows.any((r) => r['id'] == _productoId);
                return DropdownButtonFormField<String?>(
                  value: exists ? _productoId : null,
                  decoration: const InputDecoration(labelText: 'Producto'),
                  isExpanded: true,
                  onChanged: (v) {
                    final row = rows.firstWhere((r) => r['id'] == v,
                        orElse: () => const {});
                    setState(() {
                      _productoId = v;
                      _serializado = (row['es_serializado'] as int? ?? 0) == 1;
                    });
                  },
                  items: rows
                      .map((r) => DropdownMenuItem(
                            value: r['id'] as String,
                            child: Text(r['nombre'] as String),
                          ))
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _ubicaciones,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data!;
                final exists = _ubicacionId == null ||
                    rows.any((r) => r['id'] == _ubicacionId);
                return DropdownButtonFormField<String?>(
                  value: exists ? _ubicacionId : null,
                  decoration: const InputDecoration(labelText: 'Ubicación destino'),
                  isExpanded: true,
                  onChanged: (v) => setState(() => _ubicacionId = v),
                  items: rows
                      .map((r) => DropdownMenuItem(
                            value: r['id'] as String,
                            child: Text(r['nombre'] as String),
                          ))
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 12),
            // Cantidad (granel) o seriales (serializado).
            if (_productoId != null && _serializado)
              TextField(
                controller: _seriales,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Seriales (uno por línea; opcional "serial, MAC")',
                  hintText: 'SN001, AA:BB:CC:DD:EE:FF\nSN002',
                ),
              )
            else
              TextField(
                controller: _cantidad,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Cantidad'),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _costo,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Costo unitario (opcional)'),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _proveedores,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data!;
                final exists = _proveedorId == null ||
                    rows.any((r) => r['id'] == _proveedorId);
                return DropdownButtonFormField<String?>(
                  value: exists ? _proveedorId : null,
                  decoration:
                      const InputDecoration(labelText: 'Proveedor (opcional)'),
                  isExpanded: true,
                  onChanged: (v) => setState(() => _proveedorId = v),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('—')),
                    ...rows.map((r) => DropdownMenuItem(
                          value: r['id'] as String,
                          child: Text(r['nombre'] as String),
                        )),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _factura,
              decoration:
                  const InputDecoration(labelText: 'N° de factura (opcional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            if (_productoId == null || _ubicacionId == null) {
              _snack(context, 'Elegí producto y ubicación.');
              return;
            }
            final costo = double.tryParse(_costo.text.trim());
            if (_serializado) {
              // Cada línea: "serial" o "serial, MAC". Dedup por serial.
              final vistos = <String>{};
              final seriales = <({String serial, String? mac})>[];
              for (final linea in _seriales.text.split('\n')) {
                final partes = linea.split(',');
                final serial = partes[0].trim();
                if (serial.isEmpty || !vistos.add(serial)) continue;
                final mac = partes.length > 1 ? partes[1].trim() : '';
                seriales.add((serial: serial, mac: mac.isEmpty ? null : mac));
              }
              if (seriales.isEmpty) {
                _snack(context, 'Ingresá al menos un serial.');
                return;
              }
              Navigator.pop(
                context,
                _IngresoData(
                  productoId: _productoId!,
                  esSerializado: true,
                  ubicacionDestinoId: _ubicacionId!,
                  proveedorId: _proveedorId,
                  numeroFactura: _factura.text.trim().isEmpty
                      ? null
                      : _factura.text.trim(),
                  costoUnitario: costo,
                  cantidad: seriales.length.toDouble(),
                  seriales: seriales,
                ),
              );
            } else {
              final cant = double.tryParse(_cantidad.text.trim()) ?? 0;
              if (cant <= 0) {
                _snack(context, 'Cantidad inválida.');
                return;
              }
              Navigator.pop(
                context,
                _IngresoData(
                  productoId: _productoId!,
                  esSerializado: false,
                  ubicacionDestinoId: _ubicacionId!,
                  proveedorId: _proveedorId,
                  numeroFactura: _factura.text.trim().isEmpty
                      ? null
                      : _factura.text.trim(),
                  costoUnitario: costo,
                  cantidad: cant,
                  seriales: const [],
                ),
              );
            }
          },
          child: const Text('Registrar'),
        ),
      ],
    );
  }
}

String _fmtCant(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

// ===========================================================================
// EQUIPOS (seriales) + asignar a cliente
// ===========================================================================
const _estadoSerial = {
  'en_stock': 'En stock',
  'instalado': 'Instalado',
  'danado': 'Dañado',
  'retirado': 'Retirado',
  'baja': 'Baja',
};

class _EquiposTab extends ConsumerStatefulWidget {
  const _EquiposTab();
  @override
  ConsumerState<_EquiposTab> createState() => _EquiposTabState();
}

class _EquiposTabState extends ConsumerState<_EquiposTab> {
  late final Stream<List<Map<String, dynamic>>> _seriales;

  @override
  void initState() {
    super.initState();
    _seriales = ps.db.watch('''
      SELECT s.id, s.serial, s.estado, s.producto_id, s.ubicacion_id,
             p.nombre AS producto, cl.nombre AS cliente_nombre
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
   LEFT JOIN clientes cl ON cl.id = s.cliente_id
       ORDER BY p.nombre, s.serial
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _seriales,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.qr_code_2,
            titulo: 'Sin equipos',
            descripcion: 'Los equipos serializados se cargan con un ingreso.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final s = rows[i];
            final estado = s['estado'] as String? ?? 'en_stock';
            final cli = s['cliente_nombre'] as String?;
            final sub = [
              s['producto'] as String? ?? '',
              _estadoSerial[estado] ?? estado,
              if (estado == 'instalado' && cli != null) 'en $cli',
            ].join(' · ');
            return ListTile(
              leading: Icon(Icons.qr_code_2,
                  color: Theme.of(context).colorScheme.outline),
              title: Text(s['serial'] as String),
              subtitle: Text(sub),
              trailing: PopupMenuButton<String>(
                tooltip: 'Acciones',
                onSelected: (v) {
                  if (v == 'asignar') {
                    _asignar(context, s);
                  } else if (v == 'devolver') {
                    _devolver(context, s);
                  } else if (v == 'transferir') {
                    _transferir(context, s);
                  } else if (v == 'baja') {
                    _darDeBaja(context, s);
                  } else {
                    _showHistorialSerial(context, s['id'] as String);
                  }
                },
                itemBuilder: (_) => [
                  if (estado == 'en_stock') ...[
                    const PopupMenuItem(
                        value: 'asignar', child: Text('Asignar a cliente')),
                    const PopupMenuItem(
                        value: 'transferir',
                        child: Text('Transferir de ubicación')),
                  ],
                  if (estado != 'en_stock' && estado != 'baja')
                    const PopupMenuItem(
                        value: 'devolver', child: Text('Devolver a stock')),
                  if (estado != 'baja')
                    PopupMenuItem(
                        value: 'baja',
                        child: Text(
                            (estado == 'danado' || estado == 'retirado')
                                ? 'Cambiar estado'
                                : 'Dar de baja')),
                  const PopupMenuItem(
                      value: 'historial', child: Text('Historial')),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _asignar(BuildContext context, Map<String, dynamic> s) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;

    // 1. Elegir cliente.
    final cliente = await showModalBottomSheet<({String id, String nombre})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ClientePicker(),
    );
    if (cliente == null || !context.mounted) return;

    // 2. Aviso suave de red: el plan pide puerto_id para asignar equipos. Hasta
    // que la topología de red esté en producción, advertimos pero dejamos
    // seguir (se endurece a bloqueo cuando la red esté viva).
    final cli = await ps.db.getOptional(
        'SELECT puerto_id FROM clientes WHERE id = ?', [cliente.id]);
    if ((cli?['puerto_id'] as String?) == null) {
      if (!context.mounted) return;
      final seguir = await _confirmarAccion(
        context,
        titulo: 'Cliente sin red',
        mensaje: '${cliente.nombre} no tiene un puerto de red asignado. '
            'Conviene asignarle red antes del equipo. ¿Asignar igual?',
        confirmar: 'Asignar igual',
      );
      if (!seguir || !context.mounted) return;
    }

    // 3. Elegir contrato del cliente (auto si tiene uno; opcional si no tiene).
    final contratos = await ps.db.getAll('''
      SELECT ct.id, ct.codigo, ct.estado, pl.nombre AS plan
        FROM contratos ct
   LEFT JOIN planes pl ON pl.id = ct.plan_id
       WHERE ct.cliente_id = ?
       ORDER BY (ct.estado = 'activo') DESC, ct.created_at DESC
    ''', [cliente.id]);
    String? contratoId;
    if (contratos.length == 1) {
      contratoId = contratos.first['id'] as String;
    } else if (contratos.length > 1) {
      if (!context.mounted) return;
      final elegido = await showDialog<String>(
        context: context,
        builder: (_) => _ContratoPicker(contratos: contratos),
      );
      if (elegido == null || !context.mounted) return; // canceló
      contratoId = elegido;
    }

    // 4. Persistir atómico. Re-valida el estado DENTRO de la transacción para
    // evitar doble-asignación sobre data stale (otro tap / otra pestaña).
    final now = DateTime.now().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        final cur = await tx.getOptional(
            'SELECT estado, ubicacion_id, producto_id FROM inv_seriales WHERE id = ?',
            [s['id']]);
        if (cur == null || cur['estado'] != 'en_stock') {
          throw const _InvError('El equipo ya no está disponible en stock.');
        }
        await tx.execute(
          "UPDATE inv_seriales SET estado = 'instalado', cliente_id = ?, "
          "contrato_id = ?, ubicacion_id = NULL WHERE id = ?",
          [cliente.id, contratoId, s['id']],
        );
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_origen_id, cliente_id, contrato_id, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, 'asignacion', ?, ?, 1, ?, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, cur['producto_id'], s['id'],
            cur['ubicacion_id'], cliente.id, contratoId, hechoPor, now, now,
          ],
        );
      });
      _snack(context, 'Equipo asignado a ${cliente.nombre}');
    } on _InvError catch (e) {
      _snack(context, e.message);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  // Devolver un equipo (instalado/dañado/retirado) al stock, en una ubicación.
  Future<void> _devolver(BuildContext context, Map<String, dynamic> s) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final destino =
        await _pickUbicacion(context, titulo: 'Devolver a qué ubicación');
    if (destino == null || !context.mounted) return;
    final now = DateTime.now().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        final cur = await tx.getOptional(
            'SELECT estado, cliente_id, producto_id FROM inv_seriales WHERE id = ?',
            [s['id']]);
        if (cur == null) throw const _InvError('Equipo no encontrado.');
        if (cur['estado'] == 'en_stock') {
          throw const _InvError('El equipo ya está en stock.');
        }
        if (cur['estado'] == 'baja') {
          throw const _InvError('El equipo está dado de baja definitiva.');
        }
        // A1: re-validar el estado EXACTO que mostraba el menú (no solo "no
        // terminal") → evita un movimiento fantasma en el ledger si el equipo
        // cambió a otro estado intermedio en otra pestaña/device.
        if (cur['estado'] != s['estado']) {
          throw const _InvError('El equipo cambió de estado; recargá la lista.');
        }
        await tx.execute(
          "UPDATE inv_seriales SET estado = 'en_stock', cliente_id = NULL, "
          "contrato_id = NULL, ubicacion_id = ? WHERE id = ?",
          [destino.id, s['id']],
        );
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_destino_id, cliente_id, hecho_por, ocurrido_en, created_at)
             VALUES (?, ?, 'devolucion', ?, ?, 1, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, cur['producto_id'], s['id'],
            destino.id, cur['cliente_id'], hechoPor, now, now,
          ],
        );
      });
      _snack(context, 'Equipo devuelto a ${destino.nombre}');
    } on _InvError catch (e) {
      _snack(context, e.message);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  // Transferir un equipo en stock a otra ubicación.
  Future<void> _transferir(BuildContext context, Map<String, dynamic> s) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final destino = await _pickUbicacion(context,
        titulo: 'Transferir a qué ubicación',
        excluirId: s['ubicacion_id'] as String?);
    if (destino == null || !context.mounted) return;
    final now = DateTime.now().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        final cur = await tx.getOptional(
            'SELECT estado, ubicacion_id, producto_id FROM inv_seriales WHERE id = ?',
            [s['id']]);
        if (cur == null || cur['estado'] != 'en_stock') {
          throw const _InvError('Solo se puede transferir un equipo en stock.');
        }
        await tx.execute(
          'UPDATE inv_seriales SET ubicacion_id = ? WHERE id = ?',
          [destino.id, s['id']],
        );
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_origen_id, ubicacion_destino_id, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, 'transferencia', ?, ?, 1, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, cur['producto_id'], s['id'],
            cur['ubicacion_id'], destino.id, hechoPor, now, now,
          ],
        );
      });
      _snack(context, 'Equipo transferido a ${destino.nombre}');
    } on _InvError catch (e) {
      _snack(context, e.message);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  // Dar de baja un equipo (dañado/retirado/baja) → sale del stock activo.
  Future<void> _darDeBaja(BuildContext context, Map<String, dynamic> s) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    // Si el equipo ya está dañado/retirado, esto es un cambio de estado, no una
    // baja (B3): adaptamos textos. La baja definitiva está bloqueada en el menú.
    final yaDeBaja = s['estado'] == 'danado' || s['estado'] == 'retirado';
    final res = await showDialog<({String estado, String? motivo})>(
      context: context,
      builder: (_) => _BajaDialog(esCambioEstado: yaDeBaja),
    );
    if (res == null || !context.mounted) return;
    final now = DateTime.now().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        final cur = await tx.getOptional(
            'SELECT estado, ubicacion_id, cliente_id, producto_id FROM inv_seriales WHERE id = ?',
            [s['id']]);
        if (cur == null) throw const _InvError('Equipo no encontrado.');
        if (cur['estado'] == 'baja') {
          throw const _InvError('El equipo ya está dado de baja.');
        }
        // A1: re-validar el estado EXACTO que mostraba el menú dentro de la tx.
        if (cur['estado'] != s['estado']) {
          throw const _InvError('El equipo cambió de estado; recargá la lista.');
        }
        final estabaEnStock = cur['estado'] == 'en_stock';
        await tx.execute(
          'UPDATE inv_seriales SET estado = ?, cliente_id = NULL, ubicacion_id = NULL WHERE id = ?',
          [res.estado, s['id']],
        );
        await tx.execute(
          '''INSERT INTO inv_movimientos
             (id, tenant_id, tipo, producto_id, serial_id, cantidad,
              ubicacion_origen_id, cliente_id, motivo, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, 'baja', ?, ?, 1, ?, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, cur['producto_id'], s['id'],
            estabaEnStock ? cur['ubicacion_id'] : null,
            cur['cliente_id'], res.motivo, hechoPor, now, now,
          ],
        );
      });
      _snack(
          context,
          yaDeBaja
              ? 'Estado actualizado: ${_estadoSerial[res.estado] ?? res.estado}'
              : 'Equipo dado de baja (${_estadoSerial[res.estado] ?? res.estado})');
    } on _InvError catch (e) {
      _snack(context, e.message);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }
}

/// Selector de cliente (búsqueda) para asignar un equipo. Devuelve (id, nombre).
class _ClientePicker extends StatefulWidget {
  const _ClientePicker();
  @override
  State<_ClientePicker> createState() => _ClientePickerState();
}

class _ClientePickerState extends State<_ClientePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final like = '%${_q.toLowerCase()}%';
    final stream = ps.db.watch(
      '''SELECT id, nombre, codigo, cedula, telefono FROM clientes
          WHERE activo = 1 AND (
                lower(nombre) LIKE ?
             OR lower(coalesce(codigo, '')) LIKE ?
             OR lower(coalesce(cedula, '')) LIKE ?
             OR lower(coalesce(telefono, '')) LIKE ?)
          ORDER BY nombre LIMIT 50''',
      parameters: [like, like, like, like],
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar por nombre, código, cédula o teléfono',
              ),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: stream,
                initialData: const [],
                builder: (context, snap) {
                  final rows = snap.data ?? const [];
                  if (rows.isEmpty) {
                    return const Center(child: Text('Sin resultados'));
                  }
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final c = rows[i];
                      final sub = [
                        if ((c['codigo'] as String?)?.isNotEmpty ?? false)
                          c['codigo'] as String,
                        if ((c['cedula'] as String?)?.isNotEmpty ?? false)
                          c['cedula'] as String,
                      ].join(' · ');
                      return ListTile(
                        title: Text(c['nombre'] as String),
                        subtitle: sub.isEmpty ? null : Text(sub),
                        onTap: () => Navigator.pop(context, (
                          id: c['id'] as String,
                          nombre: c['nombre'] as String,
                        )),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Diálogos
// ===========================================================================
class _UbicacionDialog extends StatefulWidget {
  const _UbicacionDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_UbicacionDialog> createState() => _UbicacionDialogState();
}

class _UbicacionDialogState extends State<_UbicacionDialog> {
  late final TextEditingController _nombre;
  late String _tipo;

  @override
  void initState() {
    super.initState();
    _nombre = TextEditingController(
        text: widget.existente?['nombre'] as String? ?? '');
    _tipo = widget.existente?['tipo'] as String? ?? 'central';
  }

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nueva ubicación' : 'Editar ubicación'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nombre,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _tipo,
            decoration: const InputDecoration(labelText: 'Tipo'),
            onChanged: (v) => setState(() => _tipo = v ?? 'central'),
            items: _tiposUbicacion.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final n = _nombre.text.trim();
            if (n.isEmpty) return;
            Navigator.pop(context, (nombre: n, tipo: _tipo));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _ProveedorDialog extends StatefulWidget {
  const _ProveedorDialog({this.existente});
  final Map<String, dynamic>? existente;
  @override
  State<_ProveedorDialog> createState() => _ProveedorDialogState();
}

class _ProveedorDialogState extends State<_ProveedorDialog> {
  late final TextEditingController _nombre;
  late final TextEditingController _telefono;
  late final TextEditingController _notas;

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _telefono = TextEditingController(text: e?['telefono'] as String? ?? '');
    _notas = TextEditingController(text: e?['notas'] as String? ?? '');
  }

  @override
  void dispose() {
    _nombre.dispose();
    _telefono.dispose();
    _notas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nuevo proveedor' : 'Editar proveedor'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telefono,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Teléfono (opcional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notas,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notas (opcional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final n = _nombre.text.trim();
            if (n.isEmpty) return;
            final tel = _telefono.text.trim();
            final notas = _notas.text.trim();
            Navigator.pop(context, (
              nombre: n,
              telefono: tel.isEmpty ? null : tel,
              notas: notas.isEmpty ? null : notas,
            ));
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _ProductoData {
  const _ProductoData({
    required this.nombre,
    required this.categoriaId,
    required this.codigo,
    required this.esSerializado,
    required this.unidad,
    required this.manejaDecimal,
  });
  final String nombre;
  final String? categoriaId;
  final String? codigo;
  final bool esSerializado;
  final String unidad;
  final bool manejaDecimal;
}

class _ProductoDialog extends StatefulWidget {
  const _ProductoDialog({required this.tenantId, this.existente});
  final String tenantId;
  final Map<String, dynamic>? existente;
  @override
  State<_ProductoDialog> createState() => _ProductoDialogState();
}

class _ProductoDialogState extends State<_ProductoDialog> {
  late final TextEditingController _nombre;
  late final TextEditingController _codigo;
  String? _categoriaId;
  bool _serializado = false;
  String _unidad = 'unidad';
  bool _manejaDecimal = false;
  late final Stream<List<Map<String, dynamic>>> _categorias;

  static const _unidades = ['unidad', 'metro', 'rollo', 'caja', 'par'];

  @override
  void initState() {
    super.initState();
    final e = widget.existente;
    _nombre = TextEditingController(text: e?['nombre'] as String? ?? '');
    _codigo = TextEditingController(text: e?['codigo'] as String? ?? '');
    _categoriaId = e?['categoria_id'] as String?;
    _serializado = (e?['es_serializado'] as int? ?? 0) == 1;
    _unidad = e?['unidad'] as String? ?? 'unidad';
    _manejaDecimal = (e?['maneja_decimal'] as int? ?? 0) == 1;
    _categorias = ps.db.watch(
        'SELECT id, nombre FROM inv_categorias WHERE activo = 1 ORDER BY nombre');
  }

  @override
  void dispose() {
    _nombre.dispose();
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _crearCategoriaInline() async {
    final ctrl = TextEditingController();
    final nombre = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva categoría'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nombre'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Crear')),
        ],
      ),
    ).whenComplete(ctrl.dispose);
    if (nombre == null || nombre.isEmpty) return;
    final id = const Uuid().v4();
    try {
      await ps.db.execute(
        'INSERT INTO inv_categorias (id, tenant_id, nombre, orden, activo, created_at) VALUES (?, ?, ?, 0, 1, ?)',
        [id, widget.tenantId, nombre, DateTime.now().toIso8601String()],
      );
      if (mounted) setState(() => _categoriaId = id);
    } catch (e) {
      if (mounted) _snack(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existente == null ? 'Nuevo producto' : 'Editar producto'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nombre,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codigo,
              decoration:
                  const InputDecoration(labelText: 'Código / SKU (opcional)'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: _categorias,
                    initialData: const [],
                    builder: (context, snap) {
                      final rows = snap.data!;
                      final exists = _categoriaId == null ||
                          rows.any((r) => r['id'] == _categoriaId);
                      return DropdownButtonFormField<String?>(
                        value: exists ? _categoriaId : null,
                        decoration: const InputDecoration(
                            labelText: 'Categoría (opcional)'),
                        onChanged: (v) => setState(() => _categoriaId = v),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('—')),
                          ...rows.map((r) => DropdownMenuItem(
                                value: r['id'] as String,
                                child: Text(r['nombre'] as String),
                              )),
                        ],
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Nueva categoría',
                  onPressed: _crearCategoriaInline,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Serializado'),
              subtitle: const Text('Equipo con serial único (ONU, router…)'),
              value: _serializado,
              onChanged: (v) => setState(() => _serializado = v),
            ),
            if (!_serializado) ...[
              DropdownButtonFormField<String>(
                value: _unidad,
                decoration: const InputDecoration(labelText: 'Unidad de medida'),
                onChanged: (v) => setState(() => _unidad = v ?? 'unidad'),
                items: _unidades
                    .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                    .toList(),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Admite decimales'),
                subtitle: const Text('Ej. cable por metros (12.5)'),
                value: _manejaDecimal,
                onChanged: (v) => setState(() => _manejaDecimal = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final nombre = _nombre.text.trim();
            if (nombre.isEmpty) return;
            Navigator.pop(
              context,
              _ProductoData(
                nombre: nombre,
                categoriaId: _categoriaId,
                codigo: _codigo.text.trim().isEmpty ? null : _codigo.text.trim(),
                esSerializado: _serializado,
                unidad: _serializado ? 'unidad' : _unidad,
                manejaDecimal: _serializado ? false : _manejaDecimal,
              ),
            );
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Helpers compartidos
// ===========================================================================
void _snack(BuildContext context, String msg) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Cuenta filas (para guardas de "en uso" antes de un borrado). El SELECT debe
/// proyectar `COUNT(*) AS n`.
Future<int> _contar(String sql, List<Object?> params) async {
  final rows = await ps.db.getAll(sql, params);
  return (rows.first['n'] as int?) ?? 0;
}

/// Borra `id` de `tabla` re-chequeando la guarda de uso (`countSql` → `n`)
/// DENTRO de la transacción: cierra el TOCTOU entre el pre-check de la UI y el
/// DELETE (otro device podría haber insertado un dependiente en el medio).
/// Devuelve mensaje de error o null si borró OK.
Future<String?> _borrarSiLibre({
  required String tabla,
  required String id,
  required String countSql,
  required List<Object?> countParams,
}) async {
  try {
    await ps.db.writeTransaction((tx) async {
      final rows = await tx.getAll(countSql, countParams);
      if (((rows.first['n'] as int?) ?? 0) > 0) {
        throw const _InvError('Quedó en uso; no se eliminó.');
      }
      await tx.execute('DELETE FROM $tabla WHERE id = ?', [id]);
    });
    return null;
  } on _InvError catch (e) {
    return e.message;
  } catch (e) {
    return 'Error: $e';
  }
}

Future<bool> _confirmar(BuildContext context, String que) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Eliminar'),
      content: Text('¿Eliminar $que? No se puede deshacer.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar')),
      ],
    ),
  );
  return ok ?? false;
}

/// Confirmación genérica (título/mensaje/label propios). Para avisos suaves y
/// confirmaciones de movimientos (devolución, baja, etc.).
Future<bool> _confirmarAccion(
  BuildContext context, {
  required String titulo,
  required String mensaje,
  String confirmar = 'Confirmar',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: Text(mensaje),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(confirmar)),
      ],
    ),
  );
  return ok ?? false;
}

/// Error de negocio del inventario con mensaje apto para mostrar al usuario
/// (ej. guard de estado roto dentro de un writeTransaction).
class _InvError implements Exception {
  const _InvError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Picker de contrato cuando el cliente tiene más de uno. Devuelve el id.
class _ContratoPicker extends StatelessWidget {
  const _ContratoPicker({required this.contratos});
  final List<Map<String, dynamic>> contratos;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Elegí el contrato'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: contratos.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final c = contratos[i];
            final cod = c['codigo'] as String?;
            final plan = c['plan'] as String?;
            final estado = c['estado'] as String? ?? '';
            final sub = [
              if (plan != null && plan.isNotEmpty) plan,
              if (estado.isNotEmpty) estado,
            ].join(' · ');
            return ListTile(
              title: Text(cod != null && cod.isNotEmpty
                  ? cod
                  : (plan ?? 'Contrato')),
              subtitle: sub.isEmpty ? null : Text(sub),
              onTap: () => Navigator.pop(context, c['id'] as String),
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
      ],
    );
  }
}

/// Elegí una ubicación activa (devolución / transferencia). `excluirId` saca
/// una de la lista (ej. la ubicación origen en una transferencia).
Future<({String id, String nombre})?> _pickUbicacion(
  BuildContext context, {
  String titulo = 'Elegí la ubicación',
  String? excluirId,
}) async {
  final ubis = await ps.db.getAll(
      'SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre');
  final opciones = ubis.where((u) => u['id'] != excluirId).toList();
  if (!context.mounted) return null;
  if (opciones.isEmpty) {
    _snack(context, 'No hay ubicaciones disponibles. Creá una primero.');
    return null;
  }
  return showDialog<({String id, String nombre})>(
    context: context,
    builder: (_) => SimpleDialog(
      title: Text(titulo),
      children: [
        for (final u in opciones)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(
                context, (id: u['id'] as String, nombre: u['nombre'] as String)),
            child: Text(u['nombre'] as String),
          ),
      ],
    ),
  );
}

/// Diálogo de baja de un equipo serializado: estado destino + motivo opcional.
class _BajaDialog extends StatefulWidget {
  const _BajaDialog({this.esCambioEstado = false});
  // true si el equipo YA está dañado/retirado → es un cambio de estado, no baja.
  final bool esCambioEstado;
  @override
  State<_BajaDialog> createState() => _BajaDialogState();
}

class _BajaDialogState extends State<_BajaDialog> {
  String _estado = 'danado';
  final _motivo = TextEditingController();

  static const _opciones = {
    'danado': 'Dañado',
    'retirado': 'Retirado',
    'baja': 'Baja definitiva',
  };

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.esCambioEstado
          ? 'Cambiar estado del equipo'
          : 'Dar de baja el equipo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            value: _estado,
            decoration: const InputDecoration(labelText: 'Estado'),
            onChanged: (v) => setState(() => _estado = v ?? 'danado'),
            items: _opciones.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _motivo,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Motivo (opcional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final m = _motivo.text.trim();
            Navigator.pop(
                context, (estado: _estado, motivo: m.isEmpty ? null : m));
          },
          child: Text(widget.esCambioEstado ? 'Guardar' : 'Dar de baja'),
        ),
      ],
    );
  }
}

/// Bottom sheet: desglose del stock de un producto por ubicación. La query la
/// arma el caller (difiere serializado vs granel). Muestra solo ubicaciones con
/// stock distinto de 0.
class _StockPorUbicacionSheet extends StatefulWidget {
  const _StockPorUbicacionSheet({
    required this.titulo,
    required this.sql,
    required this.productoId,
    required this.unidad,
  });
  final String titulo;
  final String sql;
  final String productoId;
  final String unidad;

  @override
  State<_StockPorUbicacionSheet> createState() =>
      _StockPorUbicacionSheetState();
}

class _StockPorUbicacionSheetState extends State<_StockPorUbicacionSheet> {
  late final Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(widget.sql, parameters: [widget.productoId]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _stream,
          initialData: const [],
          builder: (context, snap) {
            final rows = (snap.data ?? const [])
                .where((r) => ((r['n'] as num?) ?? 0) != 0)
                .toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Stock por ubicación · ${widget.titulo}',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Sin stock en ninguna ubicación.',
                        style: TextStyle(color: scheme.outline)),
                  )
                else
                  ...rows.map((r) => ListTile(
                        dense: true,
                        leading: Icon(Icons.warehouse,
                            color: scheme.outline, size: 20),
                        title: Text(r['nombre'] as String),
                        trailing: Text(
                          '${_fmtCant((r['n'] as num?) ?? 0)} ${widget.unidad}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      )),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InvRowMenu extends StatelessWidget {
  const _InvRowMenu({
    required this.onEditar,
    required this.onHistorial,
    required this.onEliminar,
  });
  final VoidCallback onEditar;
  final VoidCallback onHistorial;
  final VoidCallback onEliminar;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Acciones',
      onSelected: (v) => switch (v) {
        'editar' => onEditar(),
        'eliminar' => onEliminar(),
        _ => onHistorial(),
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'editar', child: Text('Editar')),
        PopupMenuItem(value: 'historial', child: Text('Historial')),
        PopupMenuItem(value: 'eliminar', child: Text('Eliminar')),
      ],
    );
  }
}

void _showHistorialInv(
    BuildContext context, String tabla, String id, String titulo) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child:
                  Text(titulo, style: Theme.of(context).textTheme.titleMedium),
            ),
            HistorialCambiosWidget(tabla: tabla, registroId: id),
          ],
        ),
      ),
    ),
  );
}

/// Historial AGREGADOR del equipo: el serial + sus movimientos del ledger
/// (rastro cuna a tumba). Usa HistorialSerialWidget, no el Simple.
void _showHistorialSerial(BuildContext context, String serialId) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Historial del equipo',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            HistorialSerialWidget(serialId: serialId),
          ],
        ),
      ),
    ),
  );
}
