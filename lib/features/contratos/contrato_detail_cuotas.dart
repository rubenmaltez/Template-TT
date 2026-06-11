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
    // El botón de historial (🕐) de cada cuota se oculta al cobrador puro
    // (least-privilege: si el rol aún no cargó → null → oculto).
    // admin/admin_cobranza/super sí lo ven.
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final verHistorial = cobrador != null && !cobrador.esCobrador;
    // Ajustes de cuota (Sprint 2, 0115): solo admin/admin_cobranza, con el
    // feature habilitado por el súper y sin impersonación (el guard real es
    // server-side; esto es UI). El cobrador y el técnico no ajustan.
    final settingsSection = ref.watch(appSettingsProvider);
    final impersonando = ref.watch(estaImpersonandoProvider);
    final puedeAjustar = settingsSection.ajustesHabilitados &&
        !impersonando &&
        cobrador != null &&
        !cobrador.esCobrador &&
        cobrador.rol != 'tecnico';
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
          error: (e, _) => Center(child: Text(mensajeErrorHumano(e))),
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

            // IDs pendientes ordenados para validar orden de cobro/seleccion.
            // Los cargos manuales (reconexion, instalacion, etc.) NO entran al
            // orden obligatorio: se cobran en cualquier orden (decision de
            // negocio). Por eso se excluyen de pendingIds.
            final pendingIds = allRows
                .where((r) {
                  final e = r['estado'] as String? ?? '';
                  final esManual = r['tipo_cargo_manual'] != null;
                  return !esManual && (e == 'pendiente' || e == 'parcial');
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
                        Builder(builder: (context) {
                          final row = rows[i];
                          final cuotaId = row['id'] as String;
                          final estado = row['estado'] as String? ?? '';
                          final esManual = row['tipo_cargo_manual'] != null;
                          final esPendiente =
                              estado == 'pendiente' || estado == 'parcial';
                          final esRegularSiguiente = pendingIds.isNotEmpty &&
                              pendingIds.first == cuotaId;
                          // La fila cobrable AHORA (sin multi-select activo): la
                          // cuota regular mas antigua, o cualquier cargo manual
                          // pendiente (se cobran en cualquier orden).
                          final esCobrable = selected.isEmpty &&
                              esPendiente &&
                              (esManual || esRegularSiguiente);
                          // Atenuar las cuotas regulares pendientes que todavia
                          // NO se pueden cobrar (no son la siguiente en el orden).
                          final atenuada = selected.isEmpty &&
                              esPendiente &&
                              !esManual &&
                              !esRegularSiguiente;
                          return _CuotaRow(
                            row: row,
                            diasGracia: diasGracia,
                            isSelected: selected.contains(cuotaId),
                            showCheckbox: selected.isNotEmpty,
                            esCobrable: esCobrable,
                            atenuada: atenuada,
                            verHistorial: verHistorial,
                            onHistorial: () =>
                                _showCuotaChangeLog(context, cuotaId),
                            // Ajustes: cuotas abiertas (aplicar) o con
                            // ajustes existentes (poder QUITAR aunque el
                            // ajuste la haya dejado 'pagada' — audit F4).
                            onAjustes: puedeAjustar &&
                                    (esPendiente ||
                                        ((row['ajustes_count'] as num? ?? 0) >
                                            0))
                                ? () => _showAjustesCuota(context, row)
                                : null,
                            onTap: () {
                              if (selected.isNotEmpty &&
                                  pendingIds.contains(cuotaId)) {
                                onToggle(cuotaId, pendingIds);
                              } else if (selected.isEmpty && esPendiente) {
                                if (esManual || esRegularSiguiente) {
                                  // Cargo manual (cualquier orden) o la cuota
                                  // regular mas antigua: se puede cobrar.
                                  onTapCuota(cuotaId);
                                } else {
                                  // Falta cobrar una cuota mas antigua: avisamos
                                  // cual es (mes) para que no se sienta roto.
                                  final matchPrimera = allRows
                                      .where((r) => r['id'] == pendingIds.first);
                                  final primera = matchPrimera.isEmpty
                                      ? const <String, dynamic>{}
                                      : matchPrimera.first;
                                  final mesPrimera = primera['periodo'] != null
                                      ? Fmt.mesServicioLabel(
                                          DateTime.parse(
                                              primera['periodo'] as String),
                                          primera['tipo_cargo_manual'] != null
                                              ? null
                                              : (primera['dia_pago'] as num?)
                                                  ?.toInt())
                                      : 'la más antigua';
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'Cobrá primero $mesPrimera (la cuota más antigua pendiente).'),
                                      duration: const Duration(seconds: 3),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            },
                            onLongPress:
                                multiSelect && esPendiente && !esManual
                                    ? () => onLongPressCuota?.call(
                                        cuotaId, pendingIds)
                                    : null,
                          );
                        }),
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

  static String _filtroLabel(_CuotaFiltro f) => switch (f) {
        _CuotaFiltro.todas => 'Todas',
        _CuotaFiltro.pendientes => 'Pendientes',
        _CuotaFiltro.pagadas => 'Pagadas',
        _CuotaFiltro.manuales => 'Manuales',
      };

  // Sheet "Ajustes de la cuota" (Sprint 2, 0115): lista los ajustes con
  // quitar individual + aplicar uno nuevo. El future se cachea en el closure
  // y se recrea SOLO al recargar (no inline en cada rebuild).
  void _showAjustesCuota(BuildContext context, Map<String, dynamic> row) {
    final cuotaId = row['id'] as String;
    final montoCuota = (row['monto'] as num? ?? 0).toDouble();
    // "Aplicar" solo en cuotas abiertas; sobre una pagada el sheet sirve
    // para VER/QUITAR los ajustes existentes (quitar la reabre).
    final estadoRow = row['estado'] as String? ?? '';
    final puedeAplicar = estadoRow == 'pendiente' || estadoRow == 'parcial';
    final repo = ref.read(cuotasRepoProvider);
    Future<List<Map<String, dynamic>>>? futuro;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          futuro ??= repo.ajustesDeCuota(cuotaId);
          void recargar() =>
              setSheetState(() => futuro = repo.ajustesDeCuota(cuotaId));

          Future<void> aplicarNuevo() async {
            // Saldo FRESCO al momento de abrir el dialog (la cuota pudo
            // cambiar por otro ajuste/cobro desde que se abrió el sheet).
            final c = await repo.getById(cuotaId);
            if (c == null || !sheetCtx.mounted) return;
            final saldo = c.saldo; // getter canónico del modelo
            final ok = await showDialog<bool>(
              context: sheetCtx,
              builder: (_) => AjustarCuotaDialog(
                cuotaId: cuotaId,
                montoCuota: montoCuota,
                saldoActual: saldo,
              ),
            );
            if (ok == true && sheetCtx.mounted) recargar();
          }

          Future<void> quitar(String cargoId, double monto) async {
            final ok = await showDialog<bool>(
              context: sheetCtx,
              builder: (dCtx) => AlertDialog(
                title: const Text('¿Quitar este ajuste?'),
                content: Text(
                    'El saldo de la cuota vuelve a subir ${Fmt.cordobas(monto)}. '
                    'El ajuste queda registrado en el historial.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dCtx, false),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dCtx, true),
                    child: const Text('Quitar'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
            await repo.quitarAjuste(cargoId: cargoId);
            if (sheetCtx.mounted) recargar();
          }

          final scheme = Theme.of(sheetCtx).colorScheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ajustes de la cuota',
                      style: Theme.of(sheetCtx).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Un ajuste descuenta del saldo con motivo obligatorio y '
                    'queda en el historial de la cuota.',
                    style: Theme.of(sheetCtx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.outline),
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: futuro,
                    builder: (_, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final items = snap.data ?? const [];
                      if (items.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text('Sin ajustes aplicados.',
                              style: TextStyle(color: scheme.outline)),
                        );
                      }
                      return Column(
                        children: [
                          for (final a in items)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.percent,
                                  size: 20, color: scheme.primary),
                              title: Text(
                                '−${Fmt.cordobas((a['monto'] as num).toDouble())}'
                                '${a['porcentaje'] != null ? ' (${(a['porcentaje'] as num).toStringAsFixed(0)}%)' : ''}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                '${a['descripcion'] ?? ''}\n'
                                '${_fechaNiCorta(a['ocurrido_en'] as String?)}'
                                '${a['aplicado_por_nombre'] != null ? ' · ${a['aplicado_por_nombre']}' : ''}',
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Quitar ajuste',
                                onPressed: () => quitar(
                                  a['id'] as String,
                                  (a['monto'] as num).toDouble(),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  if (puedeAplicar)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.percent, size: 18),
                        label: const Text('Aplicar ajuste'),
                        onPressed: aplicarNuevo,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// `ocurrido_en` viene en UTC; se muestra en hora Nicaragua (UTC−6 sin
  /// DST). No usar Fmt.fechaHoraNi (es para timestamps local-naive).
  static String _fechaNiCorta(String? isoUtc) {
    if (isoUtc == null) return '';
    final dt = DateTime.tryParse(isoUtc);
    if (dt == null) return isoUtc;
    final ni = dt.toUtc().subtract(const Duration(hours: 6));
    String dos(int v) => v.toString().padLeft(2, '0');
    return '${dos(ni.day)}/${dos(ni.month)}/${ni.year} '
        '${dos(ni.hour)}:${dos(ni.minute)}';
  }

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
                child: HistorialCuotaWidget(cuotaId: cuotaId),
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

class _CuotaRow extends ConsumerWidget {
  const _CuotaRow({
    required this.row,
    required this.diasGracia,
    required this.isSelected,
    required this.showCheckbox,
    required this.esCobrable,
    required this.atenuada,
    required this.verHistorial,
    required this.onTap,
    required this.onHistorial,
    this.onAjustes,
    this.onLongPress,
  });
  final Map<String, dynamic> row;
  final int diasGracia;
  final bool isSelected;
  final bool showCheckbox;
  // Fila cobrable ahora → muestra chevron de "tocar para cobrar".
  final bool esCobrable;
  // Pendiente que todavia no se puede cobrar (orden) → atenuada.
  final bool atenuada;
  // Si false (cobrador puro), se oculta el botón 🕐 de historial.
  final bool verHistorial;
  final VoidCallback onTap;
  final VoidCallback onHistorial;
  // Ajustes de cuota (Sprint 2): null = sin permiso/feature OFF → oculto.
  final VoidCallback? onAjustes;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final colores = settings.coloresEstados;
    final diasVisibles = settings.diasCuotasVisibles;
    final estado = row['estado'] as String? ?? 'pendiente';
    final monto = (row['monto'] as num? ?? 0).toDouble();
    final montoPagado = (row['monto_pagado'] as num? ?? 0).toDouble();
    final cargosNeto = (row['cargos_neto'] as num? ?? 0).toDouble();
    final saldo = monto + cargosNeto - montoPagado;
    final periodo = DateTime.parse(row['periodo'] as String);
    final vence = DateTime.parse(row['fecha_vencimiento'] as String);

    // Día Nicaragua (B11) truncado, para coincidir con el corte SQL.
    final diasFromVence = Fmt.hoyNicaragua()
        .difference(DateTime(vence.year, vence.month, vence.day))
        .inDays;

    // Color coding. Pagada/anulada son finalizadas; pendiente/parcial se
    // clasifican por vencimiento vía estadoVisualCuota — que incluye 'fuera de
    // rango' = GRIS "no disponible" para las que vencen más allá del rango.
    final String label;
    final Color color;
    if (estado == 'pagada') {
      label = 'Pagada';
      color = Colors.green;
    } else if (estado == 'anulada') {
      label = 'Anulada';
      color = Colors.grey;
    } else if (estado == 'pendiente' || estado == 'parcial') {
      final ev = estadoVisualCuota(
        diasFromVence: diasFromVence,
        diasGracia: diasGracia,
        diasVisibles: diasVisibles,
      );
      final suf = estado == 'parcial' ? ' (parcial)' : '';
      label = switch (ev) {
        CuotaEstadoVisual.mora => 'Vencida ${diasFromVence - diasGracia}d$suf',
        CuotaEstadoVisual.gracia => 'Gracia$suf',
        CuotaEstadoVisual.hoy => 'Hoy$suf',
        CuotaEstadoVisual.proxima ||
        CuotaEstadoVisual.fueraDeRango =>
          '${-diasFromVence}d$suf',
        CuotaEstadoVisual.sinDeuda => estado,
      };
      color = colores.color(ev);
    } else {
      label = estado;
      color = scheme.outline;
    }

    // Mes de servicio (mes con más días del período): se deriva del día de
    // pago. Cargos manuales no tienen período de servicio → mes del periodo.
    final mesLabel = Fmt.mesServicioLabel(
      periodo,
      row['tipo_cargo_manual'] != null
          ? null
          : (row['dia_pago'] as num?)?.toInt(),
    );
    final esPagadaOAnulada = estado == 'pagada' || estado == 'anulada';

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected
            ? scheme.primaryContainer.withValues(alpha: 0.3)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Opacity(
          opacity: atenuada ? 0.45 : 1.0,
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
            // Ajustes de la cuota (Sprint 2): el ícono se pinta primary si
            // ya tiene ajustes aplicados (ajustes_count del provider).
            if (onAjustes != null)
              IconButton(
                icon: const Icon(Icons.percent, size: 18),
                tooltip: ((row['ajustes_count'] as num? ?? 0) > 0)
                    ? 'Ajustes aplicados'
                    : 'Ajustar cuota',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.only(left: 8),
                color: ((row['ajustes_count'] as num? ?? 0) > 0)
                    ? scheme.primary
                    : scheme.outline,
                onPressed: onAjustes,
              ),
            // Historial de cambios de la cuota (separado del tap-a-cobrar).
            // Oculto al cobrador puro (auditoría solo admin/admin_cobranza/super).
            if (verHistorial)
              IconButton(
                icon: const Icon(Icons.history, size: 18),
                tooltip: 'Historial de la cuota',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.only(left: 8),
                color: scheme.outline,
                onPressed: onHistorial,
              ),
            // Chevron de "tocar para cobrar" solo en la fila cobrable.
            if (esCobrable)
              Icon(Icons.chevron_right, size: 20, color: scheme.primary)
            else
              const SizedBox(width: 20),
          ],
        ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seccion de pagos recientes
// ---------------------------------------------------------------------------

