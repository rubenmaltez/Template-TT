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

class _CuotasListScreenState extends ConsumerState<CuotasListScreen> {
  _Filtro _filtro = _Filtro.todas;

  // Multi-select: cuota IDs seleccionadas + contrato_id para validar
  // que todas sean del mismo contrato.
  final Set<String> _selected = {};
  String? _selectedContratoId;

  Future<void> _marcarMoraComoVista() async {
    final now = DateTime.now().toUtc().toIso8601String();
    await ps.db.execute('''
      UPDATE notificaciones_mora
      SET vista_en = ?, vista_por = 'cobrador'
      WHERE vista_en IS NULL AND resuelta_en IS NULL
    ''', [now]);
  }

  void _toggleSelect(String cuotaId, String? contratoId) {
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
        // Si es de otro contrato, no seleccionar (solo mismo contrato).
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
    final multiCuotaEnabled = settings.pagoAdelantadoPermitido;

    return Stack(
      children: [
        Column(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  for (final f in _Filtro.values) ...[
                    FilterChip(
                      label: Text(_label(f)),
                      selected: _filtro == f,
                      onSelected: (_) {
                        setState(() => _filtro = f);
                        _clearSelection();
                        if (f == _Filtro.mora) _marcarMoraComoVista();
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _CuotasList(
                filtro: _filtro,
                diasGracia: diasGracia,
                multiSelect: multiCuotaEnabled,
                selected: _selected,
                selectedContratoId: _selectedContratoId,
                onToggle: _toggleSelect,
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
    required this.multiSelect,
    required this.selected,
    required this.selectedContratoId,
    required this.onToggle,
  });
  final _Filtro filtro;
  final int diasGracia;
  final bool multiSelect;
  final Set<String> selected;
  final String? selectedContratoId;
  final void Function(String cuotaId, String? contratoId) onToggle;

  @override
  State<_CuotasList> createState() => _CuotasListState();
}

class _CuotasListState extends State<_CuotasList> {
  // Cacheamos el stream de PowerSync en initState para evitar que cada
  // rebuild cree una nueva suscripción (anti-patrón ps.db.watch inline).
  // El stream se recrea en didUpdateWidget cuando cambian filtro o diasGracia.
  late Stream<List<Map<String, dynamic>>> _cuotasStream;

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(_CuotasList old) {
    super.didUpdateWidget(old);
    if (old.filtro != widget.filtro || old.diasGracia != widget.diasGracia) {
      setState(() => _cuotasStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    final (String extra, List<Object?> params) = switch (widget.filtro) {
      _Filtro.todas => (
          "AND cu.estado IN ('pendiente','parcial')",
          <Object?>[],
        ),
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

    // Mora: ordenar por comunidad → cliente (ruta del día: minimizar
    // viajes agrupando por zona). Otros filtros: por vencimiento.
    final orderBy = widget.filtro == _Filtro.mora
        ? 'ORDER BY co.nombre, c.nombre'
        : 'ORDER BY cu.fecha_vencimiento ASC, c.nombre';

    final sql = '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado, cu.contrato_id,
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
    return StreamBuilder(
      stream: _cuotasStream,
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final rows = snap.data!;
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.check_circle_outline,
            titulo: 'Nada por cobrar',
            descripcion: 'No hay cuotas que coincidan con el filtro.',
          );
        }

        // Armar lista con headers de contrato intercalados.
        // Cada "item" es un header (String) o una cuota row (Map).
        final items = <Object>[];
        String? lastContratoId;
        for (final r in rows) {
          final contratoId = r['contrato_id'] as String?;
          if (contratoId != lastContratoId) {
            final planNombre = r['plan_nombre'] as String?;
            final clienteNombre = r['cliente_nombre'] as String;
            // Header: "Plan Internet 10Mbps — Juan Pérez" o solo el cliente
            // si no hay plan (cuota manual).
            final header = planNombre != null
                ? '$planNombre  —  $clienteNombre'
                : clienteNombre;
            items.add(header);
            lastContratoId = contratoId;
          }
          items.add(r);
        }

        return ListView.builder(
          padding: EdgeInsets.only(bottom: widget.selected.length >= 2 ? 80 : 16),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item is String) {
              return _ContratoHeader(titulo: item);
            }
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
          Icon(Icons.description_outlined,
              size: 16, color: scheme.primary),
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
      title: Text(row['cliente_nombre'] as String,
          maxLines: 1, overflow: TextOverflow.ellipsis),
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
