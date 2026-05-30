part of 'contrato_detail_screen.dart';

// Sección "Historial de pagos". Visible para TODOS los roles (cobrador
// incluido) — las acciones destructivas (anular/recrear) siguen gateadas a
// admin dentro del `_PagoDetalleSheet`. Consume `contratoPagosProvider` vía
// Riverpod (mismo patrón que el resto del detalle, ver contrato_providers.dart).
class _PagosSection extends ConsumerStatefulWidget {
  const _PagosSection({required this.contratoId, required this.esAdmin});
  final String contratoId;
  final bool esAdmin;

  @override
  ConsumerState<_PagosSection> createState() => _PagosSectionState();
}

class _PagosSectionState extends ConsumerState<_PagosSection> {
  // true = más nuevos primero (el orden DESC que viene del provider).
  bool _masNuevosPrimero = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.payments, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Historial de pagos',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            // Toggle de orden: Más nuevos / Más antiguos.
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Más nuevos')),
                ButtonSegment(value: false, label: Text('Más antiguos')),
              ],
              selected: {_masNuevosPrimero},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.labelSmall,
                ),
              ),
              onSelectionChanged: (sel) =>
                  setState(() => _masNuevosPrimero = sel.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ref.watch(contratoPagosProvider(widget.contratoId)).when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (rows) {
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('Sin pagos registrados',
                      style: TextStyle(color: scheme.outline)),
                ),
              );
            }

            // El provider trae DESC (más nuevos primero). Si el user pide
            // "más antiguos", invertimos client-side la lista ya traída.
            final ordenadas = _masNuevosPrimero
                ? rows
                : rows.reversed.toList();

            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < ordenadas.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _PagoTile(row: ordenadas[i], esAdmin: widget.esAdmin),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _PagoTile extends ConsumerStatefulWidget {
  const _PagoTile({required this.row, required this.esAdmin});
  final Map<String, dynamic> row;
  final bool esAdmin;

  @override
  ConsumerState<_PagoTile> createState() => _PagoTileState();
}

class _PagoTileState extends ConsumerState<_PagoTile> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pago = Pago.fromRow(widget.row);
    final periodo = widget.row['periodo'] != null
        ? DateTime.parse(widget.row['periodo'] as String)
        : null;

    final metodoLabel = pago.metodo.label;
    final montoLabel = pago.moneda == Moneda.nio
        ? Fmt.cordobas(pago.montoCordobas)
        : '${Fmt.dolares(pago.montoOriginal)} (${Fmt.cordobas(pago.montoCordobas)})';

    return InkWell(
      onTap: _abrirDetalle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Icono
            Icon(
              pago.anulado ? Icons.block : Icons.check_circle,
              size: 20,
              color: pago.anulado ? scheme.error : Colors.green,
            ),
            const SizedBox(width: 10),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    periodo != null
                        ? Fmt.mesServicioLabel(
                            periodo,
                            widget.row['tipo_cargo_manual'] != null
                                ? null
                                : (widget.row['dia_pago'] as num?)?.toInt())
                        : '—',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      decoration:
                          pago.anulado ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    '${Fmt.fechaCorta(pago.fechaPago)} · $metodoLabel',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
              ),
            ),
            // Monto
            Text(
              montoLabel,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: pago.anulado ? scheme.error : null,
                decoration: pago.anulado ? TextDecoration.lineThrough : null,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  void _abrirDetalle() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PagoDetalleSheet(
        row: widget.row,
        esAdmin: widget.esAdmin,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom sheet con detalle completo del pago + acciones (admin)
// ---------------------------------------------------------------------------

class _PagoDetalleSheet extends ConsumerStatefulWidget {
  const _PagoDetalleSheet({required this.row, required this.esAdmin});
  final Map<String, dynamic> row;
  final bool esAdmin;

  @override
  ConsumerState<_PagoDetalleSheet> createState() => _PagoDetalleSheetState();
}

class _PagoDetalleSheetState extends ConsumerState<_PagoDetalleSheet> {
  String? _reciboId;
  String? _numeroRecibo;
  String? _cobradorNombre;
  bool _cargandoExtras = true;
  bool _ejecutandoAccion = false;

  @override
  void initState() {
    super.initState();
    _cargarExtras();
  }

  /// Carga datos no presentes en la fila del stream:
  /// - recibo.id + recibo.numero_completo (para "Ver recibo")
  /// - cobrador.nombre
  Future<void> _cargarExtras() async {
    try {
      final pagoId = widget.row['id'] as String;
      final recRows = await ps.db.getAll(
        'SELECT id, numero_completo FROM recibos WHERE pago_id = ? LIMIT 1',
        [pagoId],
      );
      final cobradorId = widget.row['cobrador_id'] as String?;
      String? nombre;
      if (cobradorId != null) {
        final cRows = await ps.db.getAll(
          'SELECT nombre FROM cobradores WHERE id = ? LIMIT 1',
          [cobradorId],
        );
        if (cRows.isNotEmpty) nombre = cRows.first['nombre'] as String?;
      }
      if (!mounted) return;
      setState(() {
        _reciboId = recRows.isNotEmpty ? recRows.first['id'] as String? : null;
        _numeroRecibo = recRows.isNotEmpty
            ? recRows.first['numero_completo'] as String?
            : null;
        _cobradorNombre = nombre;
        _cargandoExtras = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargandoExtras = false);
    }
  }

  // Abre el historial de cambios de la CUOTA asociada al pago en un bottom
  // sheet (mismo patrón que `_showChangeLog` del contrato).
  void _showCuotaChangeLog(String cuotaId) {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pago = Pago.fromRow(widget.row);
    final settings = ref.watch(appSettingsProvider);
    final periodo = widget.row['periodo'] != null
        ? DateTime.parse(widget.row['periodo'] as String)
        : null;

    final puedeAnular = widget.esAdmin && !pago.anulado;
    final puedeRecrear = pago.anulado &&
        (widget.esAdmin || settings.recrearPagoAnulado);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          top: 8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header: monto + estado
              Row(
                children: [
                  Icon(
                    pago.anulado ? Icons.block : Icons.check_circle,
                    color: pago.anulado ? scheme.error : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pago.moneda == Moneda.nio
                          ? Fmt.cordobas(pago.montoCordobas)
                          : '${Fmt.dolares(pago.montoOriginal)} '
                              '(${Fmt.cordobas(pago.montoCordobas)})',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(
                            fontWeight: FontWeight.bold,
                            decoration: pago.anulado
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                    ),
                  ),
                  if (pago.anulado)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('ANULADO',
                          style: TextStyle(
                            color: scheme.onErrorContainer,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          )),
                    ),
                  // Historial de la cuota asociada al pago (creación + cambios
                  // de estado + pagos). Esquina superior derecha del sheet.
                  if (widget.row['cuota_id'] != null)
                    IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: 'Historial de la cuota',
                      onPressed: () => _showCuotaChangeLog(
                          widget.row['cuota_id'] as String),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(),

              // Detalles
              _kv('Período',
                  periodo != null
                      ? Fmt.mesServicioLabel(
                          periodo,
                          widget.row['tipo_cargo_manual'] != null
                              ? null
                              : (widget.row['dia_pago'] as num?)?.toInt())
                      : '—'),
              _kv('Método', pago.metodo.label),
              _kv('Fecha', '${Fmt.fechaCorta(pago.fechaPago)} ${Fmt.hora(pago.fechaPago)}'),
              if (pago.referencia != null && pago.referencia!.isNotEmpty)
                _kv('Referencia', pago.referencia!),
              if (pago.notas != null && pago.notas!.isNotEmpty)
                _kv('Notas', pago.notas!),
              if (_cobradorNombre != null) _kv('Cobrador', _cobradorNombre!),
              if (_numeroRecibo != null) _kv('Recibo', _numeroRecibo!),
              if (pago.anulado && pago.motivoAnulacion != null)
                _kv('Motivo anulación', pago.motivoAnulacion!),
              if (pago.anulado && pago.anuladoEn != null)
                _kv('Anulado el',
                    '${Fmt.fechaCorta(pago.anuladoEn!)} ${Fmt.hora(pago.anuladoEn!)}'),

              // Foto comprobante
              if (pago.fotoComprobantePath != null) ...[
                const SizedBox(height: 12),
                Text('Comprobante',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                FotoComprobanteView(path: pago.fotoComprobantePath),
              ],

              const SizedBox(height: 20),
              const Divider(),

              // Acciones
              if (_cargandoExtras)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else ...[
                // Reimprimir/Ver recibo: visible para TODOS los roles
                // (cobrador necesita reimprimir su propio recibo).
                FilledButton.icon(
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Reimprimir / Ver recibo'),
                  onPressed: (_reciboId == null || _ejecutandoAccion)
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          // Cobro agrupado → abrir el recibo combinado.
                          final grupo = widget.row['grupo_cobro'] as String?;
                          context.push(grupo != null
                              ? '/recibo/$_reciboId?grupo=$grupo'
                              : '/recibo/$_reciboId');
                        },
                ),
                // Acciones destructivas: solo admin/admin_cobranza.
                if (widget.esAdmin) ...[
                  const SizedBox(height: 8),
                  if (puedeAnular)
                    OutlinedButton.icon(
                      icon: Icon(Icons.block, color: scheme.error),
                      label: Text('Anular pago',
                          style: TextStyle(color: scheme.error)),
                      onPressed:
                          _ejecutandoAccion ? null : _anular,
                    ),
                  if (puedeRecrear)
                    OutlinedButton.icon(
                      icon: Icon(Icons.replay, color: scheme.primary),
                      label: const Text('Recrear pago'),
                      onPressed:
                          _ejecutandoAccion ? null : _recrear,
                    ),
                ],
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(color: scheme.outline, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w500, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _anular() async {
    final motivo = await showDialog<String?>(
      context: context,
      builder: (_) => const _AnularPagoDialog(),
    );
    if (motivo == null || motivo.trim().isEmpty || !mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null) return;

    setState(() => _ejecutandoAccion = true);
    try {
      await ref.read(pagosRepoProvider).anularPago(
            pagoId: widget.row['id'] as String,
            anuladoPorId: me.id,
            motivo: motivo.trim(),
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago anulado')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _ejecutandoAccion = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al anular: $e')),
        );
      }
    }
  }

  Future<void> _recrear() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.replay),
        title: const Text('Recrear pago'),
        content: const Text(
          'Se va a crear un pago nuevo con los mismos datos del original. '
          'El pago anulado queda como registro histórico.\n\n'
          '¿Confirmar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Recrear'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;

    final me = ref.read(cobradorActualProvider).valueOrNull;
    if (me == null || me.prefijoRecibo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No tenés prefijo de recibo configurado')),
      );
      return;
    }

    setState(() => _ejecutandoAccion = true);
    try {
      await ref.read(pagosRepoProvider).recrearPago(
            pagoAnuladoId: widget.row['id'] as String,
            tenantId: me.tenantId,
            recreadorId: me.id,
            prefijoRecibo: me.prefijoRecibo!,
          );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pago recreado exitosamente')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _ejecutandoAccion = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al recrear: $e')),
        );
      }
    }
  }
}

// Dialog de anulación — local al sheet para no acoplarse al
// `pagos_admin_screen.dart`. Misma UX/copy.
class _AnularPagoDialog extends StatefulWidget {
  const _AnularPagoDialog();

  @override
  State<_AnularPagoDialog> createState() => _AnularPagoDialogState();
}

class _AnularPagoDialogState extends State<_AnularPagoDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'Esta acción queda registrada en auditoría. La cuota volverá '
              'a su estado anterior. El recibo emitido queda inválido.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Motivo de anulación *',
              hintText: 'Ej. Monto incorrecto, registrado por error...',
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

// ---------------------------------------------------------------------------
// Sección Documento del Contrato
// ---------------------------------------------------------------------------
// Admin/admin_cobranza pueden adjuntar/reemplazar/eliminar documento del
// contrato (PDF, Word, foto). Storage bucket: contratos-documentos.
// Path scheme: {tenant_id}/{contrato_id}/{timestamp}.{ext}

