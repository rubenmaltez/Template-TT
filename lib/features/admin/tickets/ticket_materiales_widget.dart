import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/modulos_provider.dart';
import '../../../powersync/db.dart' as ps;
import '../../../data/utils/errores.dart';

/// Cantidad sin decimales superfluos (entero si es redondo). Espeja `_fmtCant`
/// de inventario_screen (privado allá).
String _fmtCant(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

/// Materiales consumidos en un ticket (Fase 3C). Lista lo registrado + permite
/// agregar (serial de la custodia o granel). El descuento de stock lo hace el
/// trigger server-side (0106); acá sólo se inserta la fila `ticket_materiales`
/// (+ un evento 'material' en la bitácora). Gateado por el módulo `inventario`.
///
/// `tecnicoMode`: el origen del material es SU custodia (`inv_ubicaciones`
/// tipo='tecnico', cobrador_id = él); el admin elige cualquier ubicación.
class TicketMaterialesWidget extends ConsumerStatefulWidget {
  const TicketMaterialesWidget({
    super.key,
    required this.ticketId,
    required this.tenantId,
    this.clienteId,
    this.tecnicoMode = false,
  });
  final String ticketId;
  final String tenantId;

  /// Cliente del ticket. Si es null (outage), NO se permite consumir equipos
  /// serializados (no se puede instalar un serial "a nadie"); sólo granel.
  final String? clienteId;
  final bool tecnicoMode;

  @override
  ConsumerState<TicketMaterialesWidget> createState() =>
      _TicketMaterialesWidgetState();
}

class _TicketMaterialesWidgetState
    extends ConsumerState<TicketMaterialesWidget> {
  late final Stream<List<Map<String, dynamic>>> _materiales;

  @override
  void initState() {
    super.initState();
    _materiales = ps.db.watch('''
      SELECT tm.id, tm.cantidad, tm.serial_id, tm.costo_unit_snapshot,
             p.nombre AS producto, p.unidad, s.serial
        FROM ticket_materiales tm
   LEFT JOIN inv_productos p ON p.id = tm.producto_id
   LEFT JOIN inv_seriales  s ON s.id = tm.serial_id
       WHERE tm.ticket_id = ?
       ORDER BY COALESCE(tm.ocurrido_en, tm.created_at) DESC
    ''', parameters: [widget.ticketId]);
  }

  @override
  Widget build(BuildContext context) {
    // Sólo si el tenant tiene el módulo inventario encendido (además de tickets).
    final modulos = ref.watch(modulosHabilitadosProvider).valueOrNull;
    if (modulos == null || !modulos.contains('inventario')) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_2_outlined, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('Materiales',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Agregar'),
                  onPressed: _agregar,
                ),
              ],
            ),
            const SizedBox(height: 4),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _materiales,
              initialData: const [],
              builder: (context, snap) {
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('Sin materiales registrados.',
                        style: TextStyle(color: scheme.outline)),
                  );
                }
                return Column(
                  children: [
                    for (final m in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                            m['serial_id'] != null
                                ? Icons.qr_code_2
                                : Icons.category_outlined,
                            color: scheme.outline,
                            size: 20),
                        title: Text(m['producto'] as String? ?? '—'),
                        subtitle: Text(m['serial_id'] != null
                            ? 'Serial: ${m['serial'] ?? '—'}'
                            : 'Cantidad: ${_fmtCant((m['cantidad'] as num?)?.toDouble() ?? 0)} ${m['unidad'] ?? ''}'),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _agregar() async {
    // 1. Resolver las ubicaciones-origen candidatas según el rol.
    final List<Map<String, dynamic>> ubicaciones;
    if (widget.tecnicoMode) {
      final yo = ref.read(cobradorActualProvider).valueOrNull?.id;
      ubicaciones = await ps.db.getAll(
        "SELECT id, nombre FROM inv_ubicaciones "
        "WHERE cobrador_id = ? AND tipo = 'tecnico' AND activa = 1 ORDER BY nombre",
        [yo],
      );
      if (ubicaciones.isEmpty) {
        _snack('No tenés una custodia de inventario asignada. '
            'Pedile al admin que te cree una ubicación tipo "técnico".');
        return;
      }
    } else {
      ubicaciones = await ps.db.getAll(
        "SELECT id, nombre FROM inv_ubicaciones WHERE activa = 1 ORDER BY nombre",
      );
      if (ubicaciones.isEmpty) {
        _snack('No hay ubicaciones de inventario. Creá una en Inventario.');
        return;
      }
    }
    if (!mounted) return;

    final elegido = await showModalBottomSheet<_MaterialElegido>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AgregarMaterialSheet(
          ubicaciones: ubicaciones, permiteSerial: widget.clienteId != null),
    );
    if (elegido == null) return;

    // 2. Insertar el material + evento de bitácora (el trigger descuenta stock).
    // tenant_id = el del ticket (autoritativo, == current_tenant_id() del writer).
    final tenantId = widget.tenantId;
    final hechoPor = ref.read(cobradorActualProvider).valueOrNull?.id;
    final now = DateTime.now().toIso8601String();
    final ocurrido = DateTime.now().toUtc().toIso8601String();
    try {
      await ps.db.writeTransaction((tx) async {
        await tx.execute(
          '''INSERT INTO ticket_materiales
             (id, tenant_id, ticket_id, producto_id, serial_id, cantidad,
              ubicacion_origen_id, costo_unit_snapshot, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, widget.ticketId, elegido.productoId,
            elegido.serialId, elegido.cantidad, elegido.ubicacionId,
            elegido.costo, hechoPor, ocurrido, now,
          ],
        );
        await tx.execute(
          '''INSERT INTO ticket_eventos
             (id, tenant_id, ticket_id, tipo_evento, comentario, hecho_por,
              ocurrido_en, created_at)
             VALUES (?, ?, ?, 'material', ?, ?, ?, ?)''',
          [
            const Uuid().v4(), tenantId, widget.ticketId,
            elegido.descripcion, hechoPor, ocurrido, now,
          ],
        );
      });
      _snack('Material registrado. El stock se descuenta al sincronizar.');
    } catch (e) {
      _snack(mensajeErrorHumano(e));
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

/// Resultado del sheet: qué material se consume.
class _MaterialElegido {
  const _MaterialElegido({
    required this.productoId,
    required this.serialId,
    required this.cantidad,
    required this.ubicacionId,
    required this.costo,
    required this.descripcion,
  });
  final String productoId;
  final String? serialId;
  final double cantidad;
  final String ubicacionId;
  final double? costo;
  final String descripcion; // para el evento de bitácora
}

/// Sheet para elegir el material: ubicación-origen + (Serial | Granel).
class _AgregarMaterialSheet extends StatefulWidget {
  const _AgregarMaterialSheet({
    required this.ubicaciones,
    required this.permiteSerial,
  });
  final List<Map<String, dynamic>> ubicaciones;
  final bool permiteSerial; // false = ticket sin cliente → sólo granel

  @override
  State<_AgregarMaterialSheet> createState() => _AgregarMaterialSheetState();
}

class _AgregarMaterialSheetState extends State<_AgregarMaterialSheet> {
  late String _ubicacionId;
  late bool _serial; // true = serializado, false = granel
  final _cantidadCtrl = TextEditingController(text: '1');

  // Datos cargados según ubicación + modo.
  List<Map<String, dynamic>> _seriales = const [];
  List<Map<String, dynamic>> _granel = const [];
  String? _serialSel;
  String? _granelSel;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _ubicacionId = widget.ubicaciones.first['id'] as String;
    // Sin cliente (outage) no se puede instalar un serial → arrancar en granel.
    _serial = widget.permiteSerial;
    // Rebuild al tipear la cantidad → el botón "Registrar" se habilita/deshabilita.
    _cantidadCtrl.addListener(() => setState(() {}));
    _recargar();
  }

  @override
  void dispose() {
    _cantidadCtrl.dispose();
    super.dispose();
  }

  Future<void> _recargar() async {
    setState(() => _cargando = true);
    // Seriales en stock en la ubicación, EXCLUYENDO los ya consumidos local-
    // mente (pendientes de sync) — evita doble-consumo offline del mismo serial.
    final seriales = await ps.db.getAll('''
      SELECT s.id, s.serial, s.producto_id, s.costo_ingreso, p.nombre AS producto
        FROM inv_seriales s
        JOIN inv_productos p ON p.id = s.producto_id
       WHERE s.ubicacion_id = ? AND s.estado = 'en_stock'
         AND s.id NOT IN (SELECT serial_id FROM ticket_materiales
                          WHERE serial_id IS NOT NULL)
       ORDER BY p.nombre, s.serial
    ''', [_ubicacionId]);
    // Productos granel con stock > 0 en la ubicación (stock = Σdestino − Σorigen).
    final granel = await ps.db.getAll('''
      SELECT p.id, p.nombre, p.unidad, p.costo_promedio,
             COALESCE((
               SELECT SUM(CASE WHEN m.ubicacion_destino_id = ? THEN m.cantidad ELSE 0 END)
                    - SUM(CASE WHEN m.ubicacion_origen_id  = ? THEN m.cantidad ELSE 0 END)
                 FROM inv_movimientos m WHERE m.producto_id = p.id), 0) AS stock
        FROM inv_productos p
       WHERE p.es_serializado = 0 AND p.activo = 1
       ORDER BY p.nombre
    ''', [_ubicacionId, _ubicacionId]);
    final granelConStock =
        granel.where((g) => ((g['stock'] as num?) ?? 0) > 0).toList();
    if (!mounted) return;
    setState(() {
      _seriales = seriales;
      _granel = granelConStock;
      _serialSel = null;
      _granelSel = null;
      _cargando = false;
    });
  }

  void _confirmar() {
    if (_serial) {
      final s = _seriales.firstWhere((e) => e['id'] == _serialSel,
          orElse: () => const {});
      if (s.isEmpty) return;
      Navigator.pop(
        context,
        _MaterialElegido(
          productoId: s['producto_id'] as String,
          serialId: s['id'] as String,
          cantidad: 1,
          ubicacionId: _ubicacionId,
          costo: (s['costo_ingreso'] as num?)?.toDouble(),
          descripcion: 'Instaló ${s['producto']} (serial ${s['serial']})',
        ),
      );
    } else {
      final g = _granel.firstWhere((e) => e['id'] == _granelSel,
          orElse: () => const {});
      if (g.isEmpty) return;
      final cant = double.tryParse(_cantidadCtrl.text.replaceAll(',', '.'));
      if (cant == null || cant <= 0) return;
      Navigator.pop(
        context,
        _MaterialElegido(
          productoId: g['id'] as String,
          serialId: null,
          cantidad: cant,
          ubicacionId: _ubicacionId,
          costo: (g['costo_promedio'] as num?)?.toDouble(),
          descripcion:
              'Usó ${_fmtCant(cant)} ${g['unidad'] ?? ''} de ${g['nombre']}',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cantNum = double.tryParse(_cantidadCtrl.text.replaceAll(',', '.'));
    final puedeConfirmar = _serial
        ? _serialSel != null
        : (_granelSel != null && cantNum != null && cantNum > 0);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 0, 16, MediaQuery.viewInsetsOf(context).bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Agregar material',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            // Ubicación-origen (única para el técnico; lista para el admin).
            if (widget.ubicaciones.length > 1)
              DropdownButtonFormField<String>(
                initialValue: _ubicacionId,
                decoration: const InputDecoration(
                    labelText: 'Desde la ubicación', isDense: true),
                items: [
                  for (final u in widget.ubicaciones)
                    DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text(u['nombre'] as String)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _ubicacionId = v);
                  _recargar();
                },
              )
            else
              Text('Desde: ${widget.ubicaciones.first['nombre']}',
                  style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 12),
            // Sin cliente (outage) no se ofrece "Serializado": no se puede
            // instalar un equipo a un ticket sin cliente.
            if (widget.permiteSerial)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Serializado'), icon: Icon(Icons.qr_code_2)),
                  ButtonSegment(value: false, label: Text('Granel'), icon: Icon(Icons.category_outlined)),
                ],
                selected: {_serial},
                onSelectionChanged: (s) => setState(() => _serial = s.first),
              )
            else
              Text('Ticket sin cliente: sólo material a granel.',
                  style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 12),
            if (_cargando)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_serial) ...[
              if (_seriales.isEmpty)
                Text('No hay equipos serializados en stock en esta ubicación.',
                    style: TextStyle(color: scheme.outline))
              else
                DropdownButtonFormField<String>(
                  initialValue: _serialSel,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Equipo (serial)', isDense: true),
                  items: [
                    for (final s in _seriales)
                      DropdownMenuItem(
                          value: s['id'] as String,
                          child: Text('${s['producto']} · ${s['serial']}',
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _serialSel = v),
                ),
            ] else ...[
              if (_granel.isEmpty)
                Text('No hay productos a granel con stock en esta ubicación.',
                    style: TextStyle(color: scheme.outline))
              else ...[
                DropdownButtonFormField<String>(
                  initialValue: _granelSel,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Producto', isDense: true),
                  items: [
                    for (final g in _granel)
                      DropdownMenuItem(
                          value: g['id'] as String,
                          child: Text(
                              '${g['nombre']} (stock ${_fmtCant((g['stock'] as num).toDouble())})',
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _granelSel = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _cantidadCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Cantidad', isDense: true),
                ),
              ],
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('Registrar'),
              onPressed: puedeConfirmar ? _confirmar : null,
            ),
          ],
        ),
      ),
    );
  }
}
