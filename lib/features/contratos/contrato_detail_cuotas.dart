part of 'contrato_detail_screen.dart';

enum _CuotaFiltro { todas, pendientes, pagadas, manuales }

class _CuotasSection extends ConsumerStatefulWidget {
  const _CuotasSection({
    required this.contratoId,
    required this.diasGracia,
    required this.multiSelect,
    required this.selected,
    required this.filtro,
    required this.onFiltroChanged,
    required this.onToggle,
    required this.onTapCuota,
    this.onLongPressCuota,
  });
  final String contratoId;
  final int diasGracia;
  final bool multiSelect;
  final Set<String> selected;
  final _CuotaFiltro filtro;
  final ValueChanged<_CuotaFiltro> onFiltroChanged;
  final void Function(String cuotaId, List<String> orderedPendingIds) onToggle;
  final ValueChanged<String> onTapCuota;
  final void Function(String cuotaId, List<String> orderedIds)? onLongPressCuota;

  @override
  ConsumerState<_CuotasSection> createState() => _CuotasSectionState();
}

class _CuotasSectionState extends ConsumerState<_CuotasSection> {
  // false = más antiguas primero (el orden ASC que viene del provider). Es el
  // default porque las cuotas se leen cronológicamente hacia adelante.
  bool _masNuevasPrimero = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final contratoId = widget.contratoId;
    final diasGracia = widget.diasGracia;
    final multiSelect = widget.multiSelect;
    final selected = widget.selected;
    final filtro = widget.filtro;
    final onFiltroChanged = widget.onFiltroChanged;
    final onToggle = widget.onToggle;
    final onTapCuota = widget.onTapCuota;
    final onLongPressCuota = widget.onLongPressCuota;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Titulo + toggle de orden
        Row(
          children: [
            Icon(Icons.receipt_long, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Cuotas',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            // Toggle de orden: Más antiguas / Más nuevas.
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Más antiguas')),
                ButtonSegment(value: true, label: Text('Más nuevas')),
              ],
              selected: {_masNuevasPrimero},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.labelSmall,
                ),
              ),
              onSelectionChanged: (sel) =>
                  setState(() => _masNuevasPrimero = sel.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Stream de cuotas — engloba chips + lista para poder contar
        ref.watch(contratoCuotasProvider(contratoId)).when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (allRows) {

            // Contadores por filtro (incluyendo 'manuales' = sin contrato_id NO,
            // todas son del contrato actual aquí — 'manuales' = tipo_cargo_manual != null).
            int countTodas = allRows.length;
            int countPendientes = 0;
            int countPagadas = 0;
            int countManuales = 0;
            for (final r in allRows) {
              final estado = r['estado'] as String? ?? 'pendiente';
              if (estado == 'pendiente' || estado == 'parcial') countPendientes++;
              if (estado == 'pagada') countPagadas++;
              if (r['tipo_cargo_manual'] != null) countManuales++;
            }

            int countFor(_CuotaFiltro f) => switch (f) {
                  _CuotaFiltro.todas => countTodas,
                  _CuotaFiltro.pendientes => countPendientes,
                  _CuotaFiltro.pagadas => countPagadas,
                  _CuotaFiltro.manuales => countManuales,
                };

            // Filter chips con contador.
            final chips = SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in _CuotaFiltro.values) ...[
                    // 'manuales' solo se muestra si hay al menos uno.
                    if (f != _CuotaFiltro.manuales || countManuales > 0) ...[
                      FilterChip(
                        label: Text('${_filtroLabel(f)} (${countFor(f)})'),
                        selected: filtro == f,
                        onSelected: (_) => onFiltroChanged(f),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ],
              ),
            );

            // Filtrar según chip activo (siempre en orden ASC del provider).
            final filtradas = allRows.where((r) {
              final estado = r['estado'] as String? ?? 'pendiente';
              return switch (filtro) {
                _CuotaFiltro.todas => true,
                _CuotaFiltro.pendientes =>
                  estado == 'pendiente' || estado == 'parcial',
                _CuotaFiltro.pagadas => estado == 'pagada',
                _CuotaFiltro.manuales => r['tipo_cargo_manual'] != null,
              };
            }).toList();

            // Orden de DISPLAY según toggle. El cálculo de pendingIds queda
            // siempre en ASC (más abajo) para no romper el orden de selección.
            final rows = _masNuevasPrimero
                ? filtradas.reversed.toList()
                : filtradas;

            if (rows.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  chips,
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('Sin cuotas',
                          style: TextStyle(color: scheme.outline)),
                    ),
                  ),
                ],
              );
            }

            // IDs pendientes ordenados para validar orden de seleccion.
            final pendingIds = allRows
                .where((r) {
                  final e = r['estado'] as String? ?? '';
                  return e == 'pendiente' || e == 'parcial';
                })
                .map((r) => r['id'] as String)
                .toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                chips,
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _CuotaRow(
                          row: rows[i],
                          diasGracia: diasGracia,
                      isSelected: selected.contains(rows[i]['id'] as String),
                      showCheckbox: selected.isNotEmpty,
                      onHistorial: () =>
                          _showCuotaChangeLog(context, rows[i]['id'] as String),
                      onTap: () {
                        final cuotaId = rows[i]['id'] as String;
                        final estado = rows[i]['estado'] as String? ?? '';
                        if (selected.isNotEmpty && pendingIds.contains(cuotaId)) {
                          onToggle(cuotaId, pendingIds);
                        } else if (selected.isEmpty &&
                            (estado == 'pendiente' || estado == 'parcial')) {
                          onTapCuota(cuotaId);
                        }
                      },
                      onLongPress: multiSelect &&
                              _isPending(rows[i]['estado'] as String? ?? '')
                          ? () {
                              final cuotaId = rows[i]['id'] as String;
                              onLongPressCuota?.call(cuotaId, pendingIds);
                            }
                          : null,
                    ),
                  ],
                ],
              ),
            ),
              ],
            );
          },
        ),
      ],
    );
  }

  static bool _isPending(String estado) =>
      estado == 'pendiente' || estado == 'parcial';

  static String _filtroLabel(_CuotaFiltro f) => switch (f) {
        _CuotaFiltro.todas => 'Todas',
        _CuotaFiltro.pendientes => 'Pendientes',
        _CuotaFiltro.pagadas => 'Pagadas',
        _CuotaFiltro.manuales => 'Manuales',
      };

  // Abre el historial de cambios de una cuota en un bottom sheet
  // (mismo patrón que `_showChangeLog` del contrato).
  void _showCuotaChangeLog(BuildContext context, String cuotaId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Historial de la cuota',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: ctrl,
                child: HistorialCambiosWidget(
                  tabla: 'cuotas',
                  registroId: cuotaId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fila compacta de cuota (con color bar)
// ---------------------------------------------------------------------------

class _CuotaRow extends StatelessWidget {
  const _CuotaRow({
    required this.row,
    required this.diasGracia,
    required this.isSelected,
    required this.showCheckbox,
    required this.onTap,
    required this.onHistorial,
    this.onLongPress,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool isSelected;
  final bool showCheckbox;
  final VoidCallback onTap;
  final VoidCallback onHistorial;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estado = row['estado'] as String? ?? 'pendiente';
    final monto = (row['monto'] as num? ?? 0).toDouble();
    final montoPagado = (row['monto_pagado'] as num? ?? 0).toDouble();
    final saldo = monto - montoPagado;
    final periodo = DateTime.parse(row['periodo'] as String);
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);

    final hoy = DateTime.now();
    final diasFromVence =
        DateTime(hoy.year, hoy.month, hoy.day)
            .difference(DateTime(vence.year, vence.month, vence.day))
            .inDays;

    // Color coding segun estado
    final (String label, Color color) = switch (estado) {
      'pagada' => ('Pagada', Colors.green),
      'anulada' => ('Anulada', Colors.grey),
      'parcial' when diasFromVence > diasGracia =>
        ('Vencida ${diasFromVence - diasGracia}d', scheme.error),
      'parcial' when diasFromVence > 0 =>
        ('Gracia (parcial)', Colors.amber.shade700),
      'parcial' => ('Parcial', scheme.primary),
      'pendiente' when diasFromVence > diasGracia =>
        ('Vencida ${diasFromVence - diasGracia}d', scheme.error),
      'pendiente' when diasFromVence > 0 =>
        ('Gracia', Colors.amber.shade700),
      'pendiente' when diasFromVence == 0 => ('Hoy', scheme.primary),
      'pendiente' => ('${-diasFromVence}d', scheme.outline),
      _ => (estado, scheme.outline),
    };

    final mesLabel =
        '${Fmt.mes(periodo)[0].toUpperCase()}${Fmt.mes(periodo).substring(1)}';
    final esPagadaOAnulada = estado == 'pagada' || estado == 'anulada';

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected
            ? scheme.primaryContainer.withValues(alpha: 0.3)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Checkbox o color bar
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
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            // Mes + fecha vencimiento
            SizedBox(
              width: 100,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mesLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: esPagadaOAnulada ? scheme.outline : null,
                      )),
                  Text(Fmt.fechaCorta(vence),
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
            // Estado badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  )),
            ),
            const Spacer(),
            // Monto
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.cordobas(esPagadaOAnulada ? monto : saldo),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: esPagadaOAnulada ? scheme.outline : null,
                    decoration:
                        estado == 'anulada' ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (montoPagado > 0 && estado == 'parcial')
                  Text(
                    'pagado ${Fmt.cordobas(montoPagado)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.green.shade700,
                    ),
                  ),
              ],
            ),
            // Historial de cambios de la cuota (separado del tap-a-cobrar).
            IconButton(
              icon: const Icon(Icons.history, size: 18),
              tooltip: 'Historial de la cuota',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.only(left: 8),
              color: scheme.outline,
              onPressed: onHistorial,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seccion de pagos recientes
// ---------------------------------------------------------------------------

