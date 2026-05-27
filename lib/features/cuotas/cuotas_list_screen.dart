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

  void _toggleSelect(String cuotaId, String? contratoId) {
    if (contratoId == null) return;
    setState(() {
      if (_selected.contains(cuotaId)) {
        _selected.remove(cuotaId);
        if (_selected.isEmpty) _selectedContratoId = null;
      } else {
        if (_selected.isEmpty) {
          _selectedContratoId = contratoId;
          _selected.add(cuotaId);
        } else if (contratoId == _selectedContratoId) {
          _selected.add(cuotaId);
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
  final void Function(String, String?) onToggle;
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
  final void Function(String, String?) onToggle;

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
             p.nombre AS plan_nombre
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

        final items = <Object>[];
        String? lastContratoId;
        for (final r in rows) {
          final contratoId = r['contrato_id'] as String?;
          if (contratoId != lastContratoId) {
            final planNombre = r['plan_nombre'] as String?;
            final clienteNombre = r['cliente_nombre'] as String;
            final header = planNombre != null
                ? '$planNombre  —  $clienteNombre'
                : clienteNombre;
            items.add(header);
            lastContratoId = contratoId;
          }
          items.add(r);
        }

        return ListView.builder(
          padding: EdgeInsets.only(bottom: widget.selected.isNotEmpty ? 80 : 16),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item is String) return _ContratoHeader(titulo: item);
            final row = item as Map<String, dynamic>;
            final cuotaId = row['id'] as String;
            final contratoId = row['contrato_id'] as String?;
            final isSelected = widget.selected.contains(cuotaId);
            final canSelect = widget.multiSelect &&
                (widget.selected.isEmpty || contratoId == widget.selectedContratoId);
            return _CuotaListTile(
              row: row,
              diasGracia: widget.diasGracia,
              isSelected: isSelected,
              canSelect: canSelect && widget.multiSelect,
              showCheckbox: widget.selected.isNotEmpty,
              onTap: () {
                if (widget.selected.isNotEmpty) {
                  widget.onToggle(cuotaId, contratoId);
                } else {
                  context.push('/cobro/$cuotaId');
                }
              },
              onLongPress: widget.multiSelect
                  ? () => widget.onToggle(cuotaId, contratoId)
                  : null,
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

class _ContratoHeader extends StatelessWidget {
  const _ContratoHeader({required this.titulo});
  final String titulo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(Icons.description_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              titulo,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _CuotaListTile extends StatelessWidget {
  const _CuotaListTile({
    required this.row,
    required this.diasGracia,
    required this.isSelected,
    required this.canSelect,
    required this.showCheckbox,
    required this.onTap,
    this.onLongPress,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool isSelected;
  final bool canSelect;
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
    final saldo = (row['monto'] as num).toDouble() -
        (row['monto_pagado'] as num? ?? 0).toDouble();
    final diasFromVence =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
            .difference(DateTime(vence.year, vence.month, vence.day))
            .inDays;

    final (label, color, icon) = diasFromVence > diasGracia
        ? ('Vencida hace ${diasFromVence - diasGracia} día(s)', scheme.error,
            Icons.warning)
        : diasFromVence > 0
            ? ('En gracia', scheme.tertiary, Icons.schedule)
            : diasFromVence == 0
                ? ('Vence hoy', scheme.primary, Icons.event)
                : ('Vence en ${-diasFromVence} día(s)', scheme.outline,
                    Icons.event);

    return ListTile(
      selected: isSelected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.3),
      leading: showCheckbox
          ? Checkbox(
              value: isSelected,
              onChanged: canSelect ? (_) => onTap() : null,
            )
          : CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icon, color: color),
            ),
      title: Row(
        children: [
          Expanded(
            child: Text(row['cliente_nombre'] as String,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (row['contrato_id'] == null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row['comunidad'] != null)
            Text(row['comunidad'] as String,
                style: TextStyle(color: scheme.outline, fontSize: 12)),
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w500)),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Fmt.cordobas(saldo),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(Fmt.fechaCorta(vence),
              style: TextStyle(color: scheme.outline, fontSize: 11)),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
