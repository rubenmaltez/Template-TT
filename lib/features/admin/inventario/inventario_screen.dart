import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/historial_cambios_widget.dart';

/// Inventario — Sub-fase 2A: catálogo de PRODUCTOS (+ categorías inline).
/// Módulo opcional (gateado por tenant_modulos 'inventario'). Per-tenant.
/// Recepciones/movimientos/stock llegan en 2B/2C.
class InventarioScreen extends ConsumerStatefulWidget {
  const InventarioScreen({super.key});

  @override
  ConsumerState<InventarioScreen> createState() => _InventarioScreenState();
}

class _InventarioScreenState extends ConsumerState<InventarioScreen> {
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
        onPressed: () => _crearProducto(context),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _productos,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.inventory_2_outlined,
              titulo: 'Sin productos',
              accion: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar primero'),
                onPressed: () => _crearProducto(context),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(8),
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
                leading: Icon(
                    serializado ? Icons.qr_code_2 : Icons.straighten,
                    color: Theme.of(context).colorScheme.outline),
                title: Text(p['nombre'] as String),
                subtitle: Text(partes.join(' · ')),
                trailing: _InvRowMenu(
                  onEditar: () => _crearProducto(context, existente: p),
                  onHistorial: () => _showHistorialInv(context, 'inv_productos',
                      p['id'] as String, 'Historial del producto'),
                  onEliminar: () => _eliminarProducto(context, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _crearProducto(BuildContext context,
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
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _eliminarProducto(
      BuildContext context, Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar'),
        content: Text('¿Eliminar "${p['nombre']}"? No se puede deshacer.'),
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
    if (ok != true) return;
    // En 2A el producto no tiene movimientos/seriales aún. Cuando existan
    // (2C), agregar guarda de "en uso" como en red/geo.
    try {
      await ps.db.execute('DELETE FROM inv_productos WHERE id = ?', [p['id']]);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

/// Datos devueltos por el diálogo de producto.
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
    _categorias =
        ps.db.watch('SELECT id, nombre FROM inv_categorias WHERE activo = 1 ORDER BY nombre');
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
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
              decoration: const InputDecoration(labelText: 'Código / SKU (opcional)'),
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
                        decoration:
                            const InputDecoration(labelText: 'Categoría (opcional)'),
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
            // Unidad/decimal solo aplican a granel (no serializado).
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
          child: const Text('Cancelar'),
        ),
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
                // Serializado siempre por unidad, sin decimales.
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
              child: Text(titulo,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            HistorialCambiosWidget(tabla: tabla, registroId: id),
          ],
        ),
      ),
    ),
  );
}
