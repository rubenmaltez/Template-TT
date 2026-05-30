import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';

enum _Filtro { todas, mora, gracia, parciales, hoy }

class CuotasListScreen extends ConsumerStatefulWidget {
  const CuotasListScreen({super.key});

  @override
  ConsumerState<CuotasListScreen> createState() => _CuotasListScreenState();
}

class _CuotasListScreenState extends ConsumerState<CuotasListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  _Filtro _filtro = _Filtro.todas;

  final Set<String> _selected = {};
  String? _selectedContratoId;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) _clearSelection();
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _marcarMoraComoVista() async {
    final now = DateTime.now().toUtc().toIso8601String();
    await ps.db.execute('''
      UPDATE notificaciones_mora
      SET vista_en = ?, vista_por = 'cobrador'
      WHERE vista_en IS NULL AND resuelta_en IS NULL
    ''', [now]);
  }

  void _toggleSelect(String cuotaId, String? contratoId, [List<String>? orderedIds]) {
    if (contratoId == null) return;
    setState(() {
      if (_selected.contains(cuotaId)) {
        if (orderedIds != null) {
          final idx = orderedIds.indexOf(cuotaId);
          for (var i = idx; i < orderedIds.length; i++) {
            _selected.remove(orderedIds[i]);
          }
        } else {
          _selected.remove(cuotaId);
        }
        if (_selected.isEmpty) _selectedContratoId = null;
      } else {
        if (_selected.isEmpty) {
          _selectedContratoId = contratoId;
          _selected.add(cuotaId);
        } else if (contratoId == _selectedContratoId) {
          if (orderedIds != null) {
            final idx = orderedIds.indexOf(cuotaId);
            if (idx == 0 || (idx > 0 && _selected.contains(orderedIds[idx - 1]))) {
              _selected.add(cuotaId);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Debés cobrar las cuotas anteriores primero'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          } else {
            _selected.add(cuotaId);
          }
        }
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectedContratoId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final diasGracia = settings.diasGracia;
    final diasVisibles = settings.diasCuotasVisibles;
    final multiCuotaEnabled = settings.pagoAdelantadoPermitido;
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Column(
          children: [
            Material(
              color: scheme.surface,
              child: TabBar(
                controller: _tabCtrl,
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.outline,
                indicatorColor: scheme.primary,
                tabs: const [
                  Tab(icon: Icon(Icons.receipt_long, size: 18), text: 'Por cobrar'),
                  Tab(icon: Icon(Icons.people, size: 18), text: 'Por cliente'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  // Tab A: Por cobrar (con filtros)
                  _TabPorCobrar(
                    filtro: _filtro,
                    diasGracia: diasGracia,
                    diasVisibles: diasVisibles,
                    multiSelect: multiCuotaEnabled,
                    selected: _selected,
                    selectedContratoId: _selectedContratoId,
                    onToggle: _toggleSelect,
                    onFiltroChanged: (f) {
                      setState(() => _filtro = f);
                      _clearSelection();
                      if (f == _Filtro.mora) _marcarMoraComoVista();
                    },
                  ),
                  // Tab B: Por cliente
                  const _TabPorCliente(),
                ],
              ),
            ),
          ],
        ),
        if (_selected.isNotEmpty)
          Positioned(
            left: 16, right: 16, bottom: 16,
            child: Row(
              children: [
                IconButton.filledTonal(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelection,
                  tooltip: 'Cancelar selección',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.payment),
                    label: Text(_selected.length == 1
                        ? 'Cobrar cuota'
                        : 'Cobrar ${_selected.length} cuotas'),
                    onPressed: () {
                      final ids = _selected.join(',');
                      _clearSelection();
                      context.push('/cobro/$ids');
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab A: Por cobrar
// ─────────────────────────────────────────────────────────────────────────────

class _TabPorCobrar extends StatelessWidget {
  const _TabPorCobrar({
    required this.filtro,
    required this.diasGracia,
    required this.diasVisibles,
    required this.multiSelect,
    required this.selected,
    required this.selectedContratoId,
    required this.onToggle,
    required this.onFiltroChanged,
  });
  final _Filtro filtro;
  final int diasGracia;
  final int diasVisibles;
  final bool multiSelect;
  final Set<String> selected;
  final String? selectedContratoId;
  final void Function(String cuotaId, String? contratoId, [List<String>? orderedIds]) onToggle;
  final ValueChanged<_Filtro> onFiltroChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              for (final f in _Filtro.values) ...[
                FilterChip(
                  label: Text(_label(f)),
                  selected: filtro == f,
                  onSelected: (_) => onFiltroChanged(f),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        Expanded(
          child: _CuotasList(
            filtro: filtro,
            diasGracia: diasGracia,
            diasVisibles: diasVisibles,
            multiSelect: multiSelect,
            selected: selected,
            selectedContratoId: selectedContratoId,
            onToggle: onToggle,
          ),
        ),
      ],
    );
  }

  String _label(_Filtro f) => switch (f) {
        _Filtro.todas => 'Pendientes',
        _Filtro.mora => 'En mora',
        _Filtro.gracia => 'En gracia',
        _Filtro.parciales => 'Parciales',
        _Filtro.hoy => 'Vencen hoy',
      };
}

class _CuotasList extends StatefulWidget {
  const _CuotasList({
    required this.filtro,
    required this.diasGracia,
    required this.diasVisibles,
    required this.multiSelect,
    required this.selected,
    required this.selectedContratoId,
    required this.onToggle,
  });
  final _Filtro filtro;
  final int diasGracia;
  final int diasVisibles;
  final bool multiSelect;
  final Set<String> selected;
  final String? selectedContratoId;
  final void Function(String cuotaId, String? contratoId, [List<String>? orderedIds]) onToggle;

  @override
  State<_CuotasList> createState() => _CuotasListState();
}

class _CuotasListState extends State<_CuotasList> {
  late Stream<List<Map<String, dynamic>>> _cuotasStream;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(_CuotasList old) {
    super.didUpdateWidget(old);
    if (old.filtro != widget.filtro ||
        old.diasGracia != widget.diasGracia ||
        old.diasVisibles != widget.diasVisibles) {
      setState(() => _cuotasStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    // Filtro por rango: solo vencidas + próximos N días.
    // Los filtros específicos (mora, gracia, etc.) siguen funcionando igual.
    final rangoFilter = widget.filtro == _Filtro.todas
        ? "AND cu.estado IN ('pendiente','parcial') "
            "AND cu.fecha_vencimiento <= date('now', '+${widget.diasVisibles} days')"
        : '';

    final (String extra, List<Object?> params) = switch (widget.filtro) {
      _Filtro.todas => (rangoFilter, <Object?>[]),
      _Filtro.mora => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND date(cu.fecha_vencimiento, '+' || ? || ' days') < date('now')",
          <Object?>[widget.diasGracia],
        ),
      _Filtro.gracia => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND cu.fecha_vencimiento < date('now') "
              "AND date(cu.fecha_vencimiento, '+' || ? || ' days') >= date('now')",
          <Object?>[widget.diasGracia],
        ),
      _Filtro.parciales => ("AND cu.estado = 'parcial'", <Object?>[]),
      _Filtro.hoy => (
          "AND cu.estado IN ('pendiente','parcial') "
              "AND cu.fecha_vencimiento = date('now')",
          <Object?>[],
        ),
    };

    final orderBy = widget.filtro == _Filtro.mora
        ? 'ORDER BY co.nombre, c.nombre'
        : 'ORDER BY cu.fecha_vencimiento ASC, c.nombre';

    final sql = '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado, cu.contrato_id,
             cu.descripcion, cu.tipo_cargo_manual,
             c.id AS cliente_id, c.nombre AS cliente_nombre,
             co.nombre AS comunidad,
             p.nombre AS plan_nombre, ct.dia_pago
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
   LEFT JOIN contratos ct ON ct.id = cu.contrato_id
   LEFT JOIN planes p ON p.id = ct.plan_id
       WHERE c.activo = 1
         $extra
       $orderBy
    ''';

    return ps.db.watch(sql, parameters: params);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _cuotasStream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Nada por cobrar',
            descripcion: 'No hay cuotas que coincidan con el filtro.',
          );
        }

        // Agrupar por cliente_id para card-per-client.
        final byClient = <String, List<Map<String, dynamic>>>{};
        final clientOrder = <String>[];
        for (final r in rows) {
          final cid = r['cliente_id'] as String;
          if (!byClient.containsKey(cid)) {
            byClient[cid] = [];
            clientOrder.add(cid);
          }
          byClient[cid]!.add(r);
        }

        return ListView.builder(
          padding: EdgeInsets.only(
            left: 8, right: 8, top: 8,
            bottom: widget.selected.isNotEmpty ? 80 : 16,
          ),
          itemCount: clientOrder.length,
          itemBuilder: (context, i) {
            final cid = clientOrder[i];
            final cuotas = byClient[cid]!;
            final first = cuotas.first;
            final clienteNombre = first['cliente_nombre'] as String;
            final comunidad = first['comunidad'] as String?;

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header del cliente
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Icon(Icons.person, size: 18,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(clienteNombre,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  )),
                              if (comunidad != null)
                                Text(comunidad,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.outline,
                                      fontSize: 11,
                                    )),
                            ],
                          ),
                        ),
                        Text('${cuotas.length} cuota(s)',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 11,
                            )),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // Cuotas compactas — computar IDs pendientes ordenados
                  // para validar orden de pago por contrato.
                  ...() {
                    // Agrupar cuotas pendientes por contrato para orden.
                    final pendingByContrato = <String?, List<String>>{};
                    for (final c in cuotas) {
                      final e = c['estado'] as String;
                      if (e == 'pendiente' || e == 'parcial') {
                        final ctId = c['contrato_id'] as String?;
                        pendingByContrato.putIfAbsent(ctId, () => []);
                        pendingByContrato[ctId]!.add(c['id'] as String);
                      }
                    }

                    return cuotas.map((row) {
                      final cuotaId = row['id'] as String;
                      final contratoId = row['contrato_id'] as String?;
                      final isSelected = widget.selected.contains(cuotaId);
                      final pendingIds = pendingByContrato[contratoId] ?? [];
                      final canSelect = widget.multiSelect &&
                          (widget.selected.isEmpty ||
                              contratoId == widget.selectedContratoId);

                      return _CuotaCompactRow(
                        row: row,
                        diasGracia: widget.diasGracia,
                        isSelected: isSelected,
                        showCheckbox: widget.selected.isNotEmpty,
                        onTap: () {
                          if (widget.selected.isNotEmpty) {
                            widget.onToggle(cuotaId, contratoId, pendingIds);
                          } else {
                            context.push('/cobro/$cuotaId');
                          }
                        },
                        onLongPress: widget.multiSelect && canSelect
                            ? () => widget.onToggle(cuotaId, contratoId, pendingIds)
                            : null,
                      );
                    });
                  }(),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab B: Por cliente
// ─────────────────────────────────────────────────────────────────────────────

class _TabPorCliente extends StatefulWidget {
  const _TabPorCliente();

  @override
  State<_TabPorCliente> createState() => _TabPorClienteState();
}

class _TabPorClienteState extends State<_TabPorCliente> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch('''
      SELECT c.id, c.nombre,
             co.nombre AS comunidad,
             COUNT(cu.id) AS cuotas_pend,
             SUM(CASE WHEN cu.fecha_vencimiento < date('now')
                      THEN 1 ELSE 0 END) AS cuotas_vencidas,
             COALESCE(SUM(cu.monto + COALESCE(cu.cargos_neto, 0) - cu.monto_pagado), 0) AS saldo_pendiente,
             MIN(cu.fecha_vencimiento) AS vence_mas_vieja
        FROM cuotas cu
        JOIN clientes c ON c.id = cu.cliente_id
   LEFT JOIN comunidades co ON co.id = c.comunidad_id
       WHERE cu.estado IN ('pendiente','parcial')
         AND c.activo = 1
       GROUP BY c.id
       ORDER BY MIN(cu.fecha_vencimiento) ASC, c.nombre
    ''');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      initialData: const [],
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Sin clientes con deuda',
            descripcion: 'Todos los clientes están al día.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (context, i) {
            final r = rows[i];
            final cuotasPend = (r['cuotas_pend'] as num).toInt();
            final cuotasVencidas = (r['cuotas_vencidas'] as num).toInt();
            final saldo = (r['saldo_pendiente'] as num).toDouble();
            final vence = DateTime.parse(r['vence_mas_vieja'] as String);
            final diasMora = DateTime.now().difference(vence).inDays;
            final enMora = diasMora > 0;

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: enMora
                      ? scheme.errorContainer
                      : scheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    color: enMora ? scheme.error : scheme.primary,
                  ),
                ),
                title: Text(r['nombre'] as String),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r['comunidad'] as String? ?? 'Sin comunidad',
                      style: TextStyle(color: scheme.outline, fontSize: 12),
                    ),
                    Text(
                      enMora
                          ? '$cuotasVencidas vencida(s) · $diasMora día(s) en mora'
                          : '$cuotasPend cuota(s) pendiente(s)',
                      style: TextStyle(
                        color: enMora ? scheme.error : scheme.outline,
                        fontWeight: enMora ? FontWeight.w500 : null,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                trailing: Text(
                  Fmt.cordobas(saldo),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: enMora ? scheme.error : null,
                  ),
                ),
                onTap: () => context.push('/clientes/${r['id']}'),
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────────────

class _CuotaCompactRow extends StatelessWidget {
  const _CuotaCompactRow({
    required this.row,
    required this.diasGracia,
    required this.isSelected,
    required this.showCheckbox,
    required this.onTap,
    this.onLongPress,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool isSelected;
  final bool showCheckbox;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static String _tipoLabel(String tipo) => switch (tipo) {
        'reconexion' => 'Reconexión',
        'instalacion' => 'Instalación',
        'mora' => 'Mora',
        'reparacion' => 'Reparación',
        'otro' => 'Otro',
        _ => tipo,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);
    final periodo = DateTime.parse(row['periodo'] as String);
    final saldo = (row['monto'] as num).toDouble() -
        (row['monto_pagado'] as num? ?? 0).toDouble();
    final diasFromVence =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
            .difference(DateTime(vence.year, vence.month, vence.day))
            .inDays;
    final esManual = row['contrato_id'] == null;

    final (label, color) = diasFromVence > diasGracia
        ? ('Vencida ${diasFromVence - diasGracia}d', scheme.error)
        : diasFromVence > 0
            ? ('Gracia', Colors.amber.shade700)
            : diasFromVence == 0
                ? ('Hoy', scheme.primary)
                : ('${-diasFromVence}d', scheme.outline);

    // Mes de servicio (mes con más días del período de la cuota). Cargos
    // manuales y cuotas sin contrato → mes del periodo tal cual.
    final mesLabel = Fmt.mesServicioLabel(
      periodo,
      (esManual || row['tipo_cargo_manual'] != null)
          ? null
          : (row['dia_pago'] as num?)?.toInt(),
    );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected ? scheme.primaryContainer.withValues(alpha: 0.3) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (showCheckbox)
              Checkbox(
                value: isSelected,
                onChanged: (_) => onTap(),
                visualDensity: VisualDensity.compact,
              )
            else
              SizedBox(
                width: 8,
                child: Container(
                  width: 4,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            // Mes + fecha
            SizedBox(
              width: 90,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mesLabel,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  Text(Fmt.fechaCorta(vence),
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
            // Estado
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
            // Badges manuales
            if (esManual) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Manual',
                    style: TextStyle(fontSize: 9, color: scheme.onTertiaryContainer)),
              ),
              if (row['tipo_cargo_manual'] != null) ...[
                const SizedBox(width: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _tipoLabel(row['tipo_cargo_manual'] as String),
                    style: TextStyle(fontSize: 9, color: scheme.onPrimaryContainer),
                  ),
                ),
              ],
            ],
            const Spacer(),
            // Monto
            Text(Fmt.cordobas(saldo),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// Dead code removed: _ContratoHeader + _CuotaListTile (~150 lines)
// Reemplazados por _CuotaCompactRow + card-per-client inline header.
