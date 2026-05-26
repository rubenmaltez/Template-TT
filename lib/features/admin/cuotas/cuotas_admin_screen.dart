import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/formatters.dart';
import '../../../powersync/db.dart' as ps;
import '../../shared/widgets/cargar_mas_button.dart';
import '../../shared/widgets/empty_state.dart';

class CuotasAdminScreen extends ConsumerStatefulWidget {
  const CuotasAdminScreen({super.key});

  @override
  ConsumerState<CuotasAdminScreen> createState() => _CuotasAdminScreenState();
}

const int _kPageSize = 50;
const int _kSearchPageSize = 200;

class _CuotasAdminScreenState extends ConsumerState<CuotasAdminScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _estado = 'todas'; // todas / pendiente / parcial / pagada / anulada
  Timer? _debounce;
  late Stream<List<Map<String, dynamic>>> _cuotasStream;
  int _pageSize = _kPageSize;
  bool _loadingMore = false;
  Timer? _loadingMoreTimer;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final where = <String>[];
    final params = <Object?>[];
    if (_query.isNotEmpty) {
      where.add('lower(c.nombre) LIKE ?');
      params.add('%$_query%');
    }
    if (_estado != 'todas') {
      where.add('cu.estado = ?');
      params.add(_estado);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    // LIMIT como último parámetro posicional.
    params.add(_pageSize);

    // LEFT JOIN contratos y planes para que cuotas manuales (contrato_id NULL)
    // también aparezcan en la lista.
    return ps.db.watch(
      '''
      SELECT cu.*, c.nombre AS cliente, p.nombre AS plan,
             co.nombre AS cobrador
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
   LEFT JOIN planes p ON p.id = ct.plan_id
   LEFT JOIN cobradores co ON co.id = cu.cobrador_id
       $whereSql
       ORDER BY cu.fecha_vencimiento DESC, c.nombre
       LIMIT ?
      ''',
      parameters: params,
    );
  }

  int get _baseSize => _query.isEmpty ? _kPageSize : _kSearchPageSize;

  void _onLoadMore() {
    setState(() {
      _pageSize += _baseSize;
      _loadingMore = true;
      _cuotasStream = _buildStream();
    });
    _loadingMoreTimer?.cancel();
    _loadingMoreTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _loadingMore = false);
    });
  }

  void _resetPagination() {
    _pageSize = _baseSize;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    _loadingMoreTimer?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {
          _query = v.trim().toLowerCase();
          _resetPagination();
          _cuotasStream = _buildStream();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    final cuotasManuales = settings.cuotasManuales;
    final cuotasEditarMonto = settings.cuotasEditarMonto;

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Buscar por cliente',
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {
                              _query = '';
                              _resetPagination();
                              _cuotasStream = _buildStream();
                            });
                          },
                        ),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  for (final e in ['todas', 'pendiente', 'parcial', 'pagada', 'anulada']) ...[
                    ChoiceChip(
                      label: Text(e[0].toUpperCase() + e.substring(1)),
                      selected: _estado == e,
                      onSelected: (_) => setState(() {
                        _estado = e;
                        _resetPagination();
                        _cuotasStream = _buildStream();
                      }),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _cuotasStream,
                initialData: const [],
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Error: ${snap.error}'));
                  }
                  final rows = snap.data!;
                  if (rows.isEmpty) {
                    return const EmptyState(
                      icon: Icons.receipt_long,
                      titulo: 'Sin cuotas',
                    );
                  }
                  final hayMas = rows.length >= _pageSize;
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: rows.length + (hayMas ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      if (i == rows.length) {
                        return CargarMasButton(
                          loading: _loadingMore,
                          onPressed: _onLoadMore,
                        );
                      }
                      return _CuotaCard(
                        row: rows[i],
                        diasGracia: diasGracia,
                        editarMontoHabilitado: cuotasEditarMonto,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
        // FAB para crear cuota manual, visible solo si el setting está habilitado.
        if (cuotasManuales)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: () => _crearCuotaManual(context),
              icon: const Icon(Icons.add),
              label: const Text('Cuota manual'),
            ),
          ),
      ],
    );
  }

  Future<void> _crearCuotaManual(BuildContext context) async {
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null) return;

    final result = await showDialog<_CuotaManualData?>(
      context: context,
      builder: (_) => const _NuevaCuotaManualDialog(),
    );
    if (result == null || !context.mounted) return;

    try {
      final id = const Uuid().v4();
      final now = DateTime.now().toIso8601String();
      await ps.db.execute(
        '''
        INSERT INTO cuotas (
          id, tenant_id, contrato_id, cliente_id,
          periodo, fecha_vencimiento, monto, monto_pagado,
          cargos_neto, estado, descripcion, created_at
        ) VALUES (?, ?, NULL, ?, ?, ?, ?, 0, 0, 'pendiente', ?, ?)
        ''',
        [
          id,
          tenantId,
          result.clienteId,
          result.fechaVencimiento.toIso8601String().substring(0, 10),
          result.fechaVencimiento.toIso8601String().substring(0, 10),
          result.monto,
          result.descripcion,
          now,
        ],
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuota manual creada')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Datos que devuelve el dialog de cuota manual
// ---------------------------------------------------------------------------

class _CuotaManualData {
  const _CuotaManualData({
    required this.clienteId,
    required this.descripcion,
    required this.monto,
    required this.fechaVencimiento,
  });
  final String clienteId;
  final String descripcion;
  final double monto;
  final DateTime fechaVencimiento;
}

// ---------------------------------------------------------------------------
// Dialog: nueva cuota manual
// ---------------------------------------------------------------------------

class _NuevaCuotaManualDialog extends StatefulWidget {
  const _NuevaCuotaManualDialog();
  @override
  State<_NuevaCuotaManualDialog> createState() => _NuevaCuotaManualDialogState();
}

class _NuevaCuotaManualDialogState extends State<_NuevaCuotaManualDialog> {
  final _descripcionCtrl = TextEditingController();
  final _montoCtrl = TextEditingController();
  final _busquedaCtrl = TextEditingController();
  DateTime _fechaVencimiento = DateTime.now();

  String? _clienteId;
  String? _clienteNombre;

  // Búsqueda de clientes
  List<Map<String, dynamic>> _clientes = [];
  bool _buscando = false;
  Timer? _debounce;

  @override
  void dispose() {
    _descripcionCtrl.dispose();
    _montoCtrl.dispose();
    _busquedaCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _buscarClientes(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      final q = query.trim().toLowerCase();
      if (q.isEmpty) {
        setState(() => _clientes = []);
        return;
      }
      setState(() => _buscando = true);
      try {
        final like = '%$q%';
        final rows = await ps.db.getAll(
          '''
          SELECT id, nombre, telefono FROM clientes
           WHERE activo = 1
             AND (lower(nombre) LIKE ? OR lower(cedula) LIKE ? OR telefono LIKE ?)
           ORDER BY nombre
           LIMIT 20
          ''',
          [like, like, like],
        );
        if (mounted) setState(() => _clientes = rows);
      } catch (_) {
        // Silenciamos errores de búsqueda
      } finally {
        if (mounted) setState(() => _buscando = false);
      }
    });
  }

  Future<void> _seleccionarFecha() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fechaVencimiento,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('es'),
    );
    if (picked != null && mounted) {
      setState(() => _fechaVencimiento = picked);
    }
  }

  bool get _formularioValido =>
      _clienteId != null &&
      _descripcionCtrl.text.trim().isNotEmpty &&
      _montoCtrl.text.isNotEmpty &&
      (double.tryParse(_montoCtrl.text) ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nueva cuota manual'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selector de cliente
              if (_clienteId == null) ...[
                TextField(
                  controller: _busquedaCtrl,
                  onChanged: _buscarClientes,
                  decoration: InputDecoration(
                    labelText: 'Buscar cliente *',
                    prefixIcon: const Icon(Icons.person_search),
                    suffixIcon: _buscando
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                ),
                if (_clientes.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _clientes.length,
                      itemBuilder: (_, i) {
                        final c = _clientes[i];
                        return ListTile(
                          dense: true,
                          title: Text(c['nombre'] as String),
                          subtitle: c['telefono'] != null
                              ? Text(c['telefono'] as String)
                              : null,
                          onTap: () {
                            setState(() {
                              _clienteId = c['id'] as String;
                              _clienteNombre = c['nombre'] as String;
                              _clientes = [];
                              _busquedaCtrl.clear();
                            });
                          },
                        );
                      },
                    ),
                  ),
              ] else ...[
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Cliente',
                    border: OutlineInputBorder(),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text(_clienteNombre ?? '')),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          _clienteId = null;
                          _clienteNombre = null;
                        }),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // Descripción
              TextField(
                controller: _descripcionCtrl,
                decoration: const InputDecoration(
                  labelText: 'Descripción *',
                  hintText: 'Ej: Cargo por reconexión, Instalación...',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              // Monto
              TextField(
                controller: _montoCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Monto (C\$) *',
                  prefixText: 'C\$ ',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              // Fecha de vencimiento
              InkWell(
                onTap: _seleccionarFecha,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Fecha de vencimiento',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(Fmt.fechaCorta(_fechaVencimiento)),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _formularioValido
              ? () {
                  Navigator.pop(
                    context,
                    _CuotaManualData(
                      clienteId: _clienteId!,
                      descripcion: _descripcionCtrl.text.trim(),
                      monto: double.parse(_montoCtrl.text),
                      fechaVencimiento: _fechaVencimiento,
                    ),
                  );
                }
              : null,
          child: const Text('Crear cuota'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Dialog: editar monto de cuota
// ---------------------------------------------------------------------------

class _EditarMontoCuotaDialog extends StatefulWidget {
  const _EditarMontoCuotaDialog({required this.montoActual});
  final double montoActual;

  @override
  State<_EditarMontoCuotaDialog> createState() => _EditarMontoCuotaDialogState();
}

class _EditarMontoCuotaDialogState extends State<_EditarMontoCuotaDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    // Mostrar sin decimales si es entero, con 2 decimales si no.
    final txt = widget.montoActual == widget.montoActual.roundToDouble()
        ? widget.montoActual.toInt().toString()
        : widget.montoActual.toStringAsFixed(2);
    _ctrl = TextEditingController(text: txt);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar monto'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Monto actual: ${Fmt.cordobas(widget.montoActual)}'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Nuevo monto (C\$) *',
              prefixText: 'C\$ ',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final v = double.tryParse(_ctrl.text);
            if (v == null || v <= 0) return;
            Navigator.pop(context, v);
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Card de cuota individual
// ---------------------------------------------------------------------------

class _CuotaCard extends ConsumerWidget {
  const _CuotaCard({
    required this.row,
    required this.diasGracia,
    required this.editarMontoHabilitado,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool editarMontoHabilitado;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final estado = row['estado'] as String;
    final monto = (row['monto'] as num).toDouble();
    final pagado = (row['monto_pagado'] as num? ?? 0).toDouble();
    final saldo = monto - pagado;
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);
    final periodo = DateTime.parse(row['periodo'] as String);
    final planNombre = row['plan'] as String?;
    final descripcion = row['descripcion'] as String?;
    final esManual = row['contrato_id'] == null;

    final (color, label) = _displayEstado(estado, vence, diasGracia, scheme);

    // Subtexto: para cuotas manuales mostramos descripción, para normales el plan.
    final subtexto = esManual
        ? (descripcion ?? 'Cuota manual')
        : '${planNombre ?? '?'} · ${Fmt.mes(periodo)[0].toUpperCase()}${Fmt.mes(periodo).substring(1)}';

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(_icon(estado, vence, diasGracia), color: color),
        ),
        title: Row(
          children: [
            Expanded(child: Text(row['cliente'] as String)),
            if (esManual)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Manual',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtexto,
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
            Text('Vence ${Fmt.fechaCorta(vence)} · $label',
                style: TextStyle(color: color, fontSize: 12)),
            if (row['cobrador'] != null)
              Text('Cobrador: ${row['cobrador']}',
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(Fmt.cordobas(monto),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  decoration: estado == 'anulada' ? TextDecoration.lineThrough : null,
                )),
            if (estado != 'pagada' && estado != 'anulada' && pagado > 0)
              Text('Saldo: ${Fmt.cordobas(saldo)}',
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
          ],
        ),
        onTap: estado != 'anulada' && estado != 'pagada'
            ? () => _accionesCuota(context, ref)
            : null,
      ),
    );
  }

  IconData _icon(String estado, DateTime vence, int dg) {
    if (estado == 'pagada') return Icons.check_circle;
    if (estado == 'anulada') return Icons.block;
    final diff = DateTime.now().difference(vence).inDays;
    if (diff > dg) return Icons.warning;
    if (diff > 0) return Icons.schedule;
    return Icons.event;
  }

  (Color, String) _displayEstado(
      String estado, DateTime vence, int dg, ColorScheme s) {
    if (estado == 'pagada') return (s.tertiary, 'Pagada');
    if (estado == 'anulada') return (s.outline, 'Anulada');
    final diff = DateTime.now().difference(vence).inDays;
    if (diff > dg) return (s.error, 'Vencida hace ${diff - dg} día(s)');
    if (diff > 0) return (s.tertiary, 'En gracia');
    if (diff == 0) return (s.primary, 'Vence hoy');
    return (s.outline, 'Al día');
  }

  Future<void> _accionesCuota(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            if (editarMontoHabilitado)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Editar monto'),
                subtitle: const Text('Modificar el monto de la cuota'),
                onTap: () async {
                  Navigator.pop(context);
                  await _editarMonto(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Anular cuota'),
              subtitle: const Text('No se podrá cobrar más'),
              onTap: () async {
                Navigator.pop(context);
                await _anular(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editarMonto(BuildContext context) async {
    final montoActual = (row['monto'] as num).toDouble();
    final nuevoMonto = await showDialog<double?>(
      context: context,
      builder: (_) => _EditarMontoCuotaDialog(montoActual: montoActual),
    );
    if (nuevoMonto == null || nuevoMonto == montoActual || !context.mounted) {
      return;
    }

    try {
      await ps.db.execute(
        'UPDATE cuotas SET monto = ? WHERE id = ?',
        [nuevoMonto, row['id']],
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Monto actualizado: ${Fmt.cordobas(montoActual)} -> ${Fmt.cordobas(nuevoMonto)}',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _anular(BuildContext context, WidgetRef ref) async {
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularCuotaDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !context.mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    try {
      await ps.db.execute(
        '''
        UPDATE cuotas
           SET estado = 'anulada',
               anulada_en = ?,
               anulada_por = ?,
               motivo_anulacion = ?
         WHERE id = ?
        ''',
        [DateTime.now().toIso8601String(), me.id, motivo.trim(), row['id']],
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cuota anulada')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

class _AnularCuotaDialog extends StatefulWidget {
  const _AnularCuotaDialog();
  @override
  State<_AnularCuotaDialog> createState() => _AnularCuotaDialogState();
}

class _AnularCuotaDialogState extends State<_AnularCuotaDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular cuota'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Esta acción se registra en auditoría. '
              'Los pagos ya aplicados a esta cuota no se modifican.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo *',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_ctrl.text.trim().isEmpty) return;
            Navigator.pop(context, _ctrl.text);
          },
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}
