import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
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
      length: 4,
      child: Column(
        children: const [
          TabBar(isScrollable: true, tabs: [
            Tab(text: 'Existencias'),
            Tab(text: 'Productos'),
            Tab(text: 'Ubicaciones'),
            Tab(text: 'Proveedores'),
          ]),
          Expanded(
            child: TabBarView(children: [
              _ExistenciasTab(),
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
    if (!await _confirmar(context, '"${p['nombre']}"')) return;
    // En 2B el producto no tiene movimientos/seriales aún (llegan en 2C). Ahí
    // se agrega la guarda de "en uso" como en red/geo.
    try {
      await ps.db.execute('DELETE FROM inv_productos WHERE id = ?', [p['id']]);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
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
    if (!await _confirmar(context, '"${u['nombre']}"')) return;
    // En 2C habrá movimientos referenciando ubicaciones → agregar guarda ahí.
    try {
      await ps.db.execute('DELETE FROM inv_ubicaciones WHERE id = ?', [u['id']]);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
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
    if (!await _confirmar(context, '"${p['nombre']}"')) return;
    try {
      await ps.db.execute('DELETE FROM inv_proveedores WHERE id = ?', [p['id']]);
    } catch (e) {
      _snack(context, 'Error: $e');
    }
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
    // Stock TOTAL por producto = Σ(cantidad con destino) − Σ(cantidad con
    // origen) sobre el ledger. Las transferencias internas netean a 0.
    _stock = ps.db.watch('''
      SELECT p.id, p.nombre, p.unidad, p.es_serializado,
             COALESCE((
               SELECT SUM(CASE WHEN m.ubicacion_destino_id IS NOT NULL THEN m.cantidad ELSE 0 END)
                    - SUM(CASE WHEN m.ubicacion_origen_id  IS NOT NULL THEN m.cantidad ELSE 0 END)
                 FROM inv_movimientos m WHERE m.producto_id = p.id
             ), 0) AS stock
        FROM inv_productos p
       WHERE p.activo = 1
       ORDER BY p.nombre
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_box),
        label: const Text('Ingreso'),
        onPressed: () => _ingreso(context),
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
              return ListTile(
                leading: Icon(Icons.inventory,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(r['nombre'] as String),
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
    try {
      if (res.esSerializado) {
        // Validar que ningún serial ya exista en el tenant (UNIQUE).
        for (final s in res.seriales) {
          final dup = await ps.db.getAll(
            'SELECT 1 FROM inv_seriales WHERE tenant_id = ? AND serial = ? LIMIT 1',
            [tenantId, s],
          );
          if (dup.isNotEmpty) {
            _snack(context, 'El serial "$s" ya existe.');
            return;
          }
        }
        for (final s in res.seriales) {
          final serialId = const Uuid().v4();
          await ps.db.execute(
            '''INSERT INTO inv_seriales
               (id, tenant_id, producto_id, serial, estado, ubicacion_id,
                costo_ingreso, created_at)
               VALUES (?, ?, ?, ?, 'en_stock', ?, ?, ?)''',
            [serialId, tenantId, res.productoId, s, res.ubicacionDestinoId,
              res.costoUnitario, now],
          );
          await _movIngreso(tenantId, res, productoSerialId: serialId,
              cantidad: 1, hechoPor: hechoPor, now: now);
        }
      } else {
        await _movIngreso(tenantId, res, productoSerialId: null,
            cantidad: res.cantidad, hechoPor: hechoPor, now: now);
      }
    } catch (e) {
      _snack(context, 'Error: $e');
    }
  }

  Future<void> _movIngreso(String tenantId, _IngresoData res,
      {required String? productoSerialId,
      required double cantidad,
      required String? hechoPor,
      required String now}) {
    return ps.db.execute(
      '''INSERT INTO inv_movimientos
         (id, tenant_id, tipo, producto_id, serial_id, cantidad,
          ubicacion_destino_id, proveedor_id, numero_factura, costo_unitario,
          hecho_por, ocurrido_en, created_at)
         VALUES (?, ?, 'ingreso', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        const Uuid().v4(), tenantId, res.productoId, productoSerialId, cantidad,
        res.ubicacionDestinoId, res.proveedorId, res.numeroFactura,
        res.costoUnitario, hechoPor, now, now,
      ],
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
  final List<String> seriales;
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
                  labelText: 'Seriales (uno por línea)',
                  hintText: 'SN001\nSN002',
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
              final seriales = _seriales.text
                  .split('\n')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toSet()
                  .toList();
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
