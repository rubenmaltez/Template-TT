import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/pagos_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_comprobante_view.dart';
import '../shared/widgets/historial_cambios_widget.dart';

part 'contrato_detail_header.dart';
part 'contrato_detail_cuotas.dart';
part 'contrato_detail_pagos.dart';
part 'contrato_detail_documento.dart';

// ---------------------------------------------------------------------------
// ContratoDetailScreen — detalle de contrato con cuotas y pagos.
// ---------------------------------------------------------------------------

class ContratoDetailScreen extends ConsumerStatefulWidget {
  const ContratoDetailScreen({super.key, required this.contratoId});
  final String contratoId;

  @override
  ConsumerState<ContratoDetailScreen> createState() =>
      _ContratoDetailScreenState();
}

class _ContratoDetailScreenState extends ConsumerState<ContratoDetailScreen> {
  // --- streams (late final + didUpdateWidget defensivo) ---
  late Stream<List<Map<String, dynamic>>> _contratoStream;
  late Stream<List<Map<String, dynamic>>> _cuotasStream;
  late Stream<List<Map<String, dynamic>>> _pagosStream;
  // Stream para el resumen — agrega SUM de todos los pagos NO anulados del
  // contrato (incluye pagos a cuotas regulares Y a cargos manuales).
  late Stream<List<Map<String, dynamic>>> _resumenStream;

  // --- multi-select ---
  final Set<String> _selected = {};
  _CuotaFiltro _filtro = _CuotaFiltro.todas;

  @override
  void initState() {
    super.initState();
    _contratoStream = _buildContratoStream();
    _cuotasStream = _buildCuotasStream();
    _pagosStream = _buildPagosStream();
    _resumenStream = _buildResumenStream();
  }

  @override
  void didUpdateWidget(ContratoDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.contratoId != widget.contratoId) {
      setState(() {
        _contratoStream = _buildContratoStream();
        _cuotasStream = _buildCuotasStream();
        _pagosStream = _buildPagosStream();
        _resumenStream = _buildResumenStream();
        _selected.clear();
      });
    }
  }

  // --- stream builders ---

  Stream<List<Map<String, dynamic>>> _buildContratoStream() {
    return ps.db.watch(
      '''
      SELECT ct.id, ct.tenant_id, ct.dia_pago, ct.fecha_inicio, ct.fecha_fin,
             ct.estado, ct.cliente_id, ct.cobrador_id,
             ct.documento_path,
             p.nombre AS plan_nombre, p.precio_mensual,
             c.nombre AS cliente_nombre
        FROM contratos ct
        JOIN planes  p ON p.id = ct.plan_id
        JOIN clientes c ON c.id = ct.cliente_id
       WHERE ct.id = ?
       LIMIT 1
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  Stream<List<Map<String, dynamic>>> _buildCuotasStream() {
    return ps.db.watch(
      '''
      SELECT cu.id, cu.monto, cu.monto_pagado, cu.fecha_vencimiento,
             cu.periodo, cu.estado, cu.contrato_id,
             cu.descripcion, cu.tipo_cargo_manual
        FROM cuotas cu
       WHERE cu.contrato_id = ?
       ORDER BY cu.periodo ASC
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  Stream<List<Map<String, dynamic>>> _buildPagosStream() {
    return ps.db.watch(
      '''
      SELECT pa.id, pa.tenant_id, pa.cuota_id, pa.cobrador_id,
             pa.monto_cordobas, pa.vuelto_cordobas, pa.moneda,
             pa.monto_original, pa.tasa_conversion, pa.metodo,
             pa.referencia, pa.foto_comprobante_path,
             pa.lat, pa.lng, pa.notas, pa.fecha_pago,
             pa.anulado, pa.anulado_en, pa.anulado_por,
             pa.motivo_anulacion, pa.grupo_cobro, pa.client_local_id,
             cu.periodo
        FROM pagos pa
        INNER JOIN cuotas cu ON cu.id = pa.cuota_id
       WHERE cu.contrato_id = ?
       ORDER BY pa.fecha_pago DESC
       LIMIT 20
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  // Resumen: SUM(monto_pagado) de pagos NO anulados del contrato.
  // Incluye pagos a cuotas regulares Y a cargos manuales del mismo contrato.
  Stream<List<Map<String, dynamic>>> _buildResumenStream() {
    return ps.db.watch(
      '''
      SELECT COALESCE(SUM(pa.monto_cordobas), 0) AS recaudado
        FROM pagos pa
        JOIN cuotas cu ON cu.id = pa.cuota_id
       WHERE cu.contrato_id = ?
         AND pa.anulado = 0
      ''',
      parameters: [widget.contratoId],
    ).asBroadcastStream();
  }

  // --- multi-select helpers ---

  void _toggleSelect(String cuotaId, List<String> orderedPendingIds) {
    setState(() {
      if (_selected.contains(cuotaId)) {
        // Al deseleccionar, quitar esta y todas las posteriores.
        final idx = orderedPendingIds.indexOf(cuotaId);
        for (var i = idx; i < orderedPendingIds.length; i++) {
          _selected.remove(orderedPendingIds[i]);
        }
      } else {
        // Solo permitir seleccionar si es la primera o la anterior ya
        // está seleccionada (consecutivas desde la más vieja).
        final idx = orderedPendingIds.indexOf(cuotaId);
        if (idx == 0 || (idx > 0 && _selected.contains(orderedPendingIds[idx - 1]))) {
          _selected.add(cuotaId);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Debes cobrar las cuotas anteriores primero'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    });
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  // --- estado del contrato ---

  Future<void> _cambiarEstado(String nuevoEstado) async {
    await ps.db.execute(
      'UPDATE contratos SET estado = ? WHERE id = ?',
      [nuevoEstado, widget.contratoId],
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Estado cambiado a $nuevoEstado')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdmin = cobrador != null &&
        (cobrador.esAdmin || cobrador.esAdminCobranza || cobrador.esSuperAdmin);
    final settings = ref.watch(appSettingsProvider);
    final multiCuotaEnabled = settings.pagoAdelantadoPermitido;
    final diasGracia = settings.diasGracia;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Detalle del contrato'),
        actions: [
          if (esAdmin)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de cambios',
              onPressed: () => _showChangeLog(context),
            ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _contratoStream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.assignment_outlined,
              titulo: 'Contrato no encontrado',
            );
          }
          final contrato = rows.first;

          return Stack(
            children: [
              // En pantallas anchas centramos el contenido con un maxWidth
              // razonable (no estira la lectura infinitamente). Mobile/tablet
              // chico usan el ancho completo.
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: ListView(
                padding: EdgeInsets.only(
                  left: 16, right: 16, top: 16,
                  bottom: _selected.isNotEmpty ? 96 : 16,
                ),
                children: [
                  _ContratoHeader(
                    contrato: contrato,
                    esAdmin: esAdmin,
                    onEstadoChanged: esAdmin ? _cambiarEstado : null,
                    resumenStream: _resumenStream,
                  ),
                  const SizedBox(height: 24),
                  _CuotasSection(
                    cuotasStream: _cuotasStream,
                    diasGracia: diasGracia,
                    multiSelect: multiCuotaEnabled,
                    selected: _selected,
                    filtro: _filtro,
                    onFiltroChanged: (f) {
                      setState(() => _filtro = f);
                      _clearSelection();
                    },
                    onToggle: _toggleSelect,
                    onTapCuota: (cuotaId) => context.push('/cobro/$cuotaId'),
                    onLongPressCuota: multiCuotaEnabled
                        ? (cuotaId, orderedIds) =>
                            _toggleSelect(cuotaId, orderedIds)
                        : null,
                  ),
                  const SizedBox(height: 24),
                  _DocumentoContratoSection(
                    contratoId: widget.contratoId,
                    documentoPath: contrato['documento_path'] as String?,
                    tenantId: contrato['tenant_id'] as String? ?? '',
                    esAdmin: esAdmin,
                  ),
                  const SizedBox(height: 24),
                  _PagosSection(
                    pagosStream: _pagosStream,
                    esAdmin: esAdmin,
                  ),
                ],
              ),
                ),
              ),
              // FAB multi-cobro
              // FAB multi-cobro: respeta el mismo maxWidth (1100) que el
              // contenido para no estirarse en pantallas anchas.
              if (_selected.isNotEmpty)
                Positioned(
                  left: 0, right: 0, bottom: 16,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _showChangeLog(BuildContext context) {
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
              child: Text('Historial de cambios',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: ctrl,
                child: HistorialCambiosWidget(
                  tabla: 'contratos',
                  registroId: widget.contratoId,
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
// Header del contrato
// ---------------------------------------------------------------------------

