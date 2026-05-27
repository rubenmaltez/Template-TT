import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/cuota.dart';
import '../../data/models/pago.dart';
import '../../data/providers/cobrador_provider.dart';
import '../../data/repositories/clientes_repo.dart';
import '../../data/repositories/settings_repo.dart';
import '../../data/services/external_actions.dart';
import '../../data/services/visitas_service.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/historial_cambios_widget.dart';

class ClienteDetailScreen extends ConsumerStatefulWidget {
  const ClienteDetailScreen({super.key, required this.clienteId});
  final String clienteId;

  @override
  ConsumerState<ClienteDetailScreen> createState() =>
      _ClienteDetailScreenState();
}

class _ClienteDetailScreenState extends ConsumerState<ClienteDetailScreen> {
  final _visitasKey = GlobalKey<_VisitasSectionState>();
  Set<String> _selectedCuotas = {};

  void _showHistorial(BuildContext context, String tabla, String registroId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Historial de cambios',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: HistorialCambiosWidget(
                  tabla: tabla,
                  registroId: registroId,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clienteAsync = ref.watch(clienteByIdProvider(widget.clienteId));
    final diasGracia = ref.watch(appSettingsProvider).diasGracia;
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esCobrador = cobrador?.rol == 'cobrador';
    final loc = GoRouterState.of(context).uri.path;
    final enAdminShell = loc.startsWith('/admin');

    return Scaffold(
      appBar: AppBar(
        title: clienteAsync.when(
          data: (c) => Text(c?.nombre ?? 'Cliente'),
          loading: () => const Text('Cliente'),
          error: (_, __) => const Text('Cliente'),
        ),
        actions: [
          if (esAdmin)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Editar cliente',
              onPressed: () {
                final editPath = enAdminShell
                    ? '/admin/clientes/${widget.clienteId}/editar'
                    : '/clientes/${widget.clienteId}/editar';
                context.push(editPath);
              },
            ),
          if (esAdmin)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de cambios',
              onPressed: () => _showHistorial(context, 'clientes', widget.clienteId),
            ),
        ],
      ),
      floatingActionButton: _selectedCuotas.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () {
                final ids = _selectedCuotas.join(',');
                setState(() => _selectedCuotas = {});
                context.push('/cobro/$ids');
              },
              icon: const Icon(Icons.payment),
              label: Text(_selectedCuotas.length == 1
                  ? 'Cobrar cuota'
                  : 'Cobrar ${_selectedCuotas.length} cuotas'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _mostrarDialogVisita(context),
              icon: const Icon(Icons.add_task),
              label: const Text('Registrar visita'),
            ),
      body: clienteAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (cliente) {
          if (cliente == null) {
            return const EmptyState(
              icon: Icons.person_off,
              titulo: 'Cliente no encontrado',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              _ClienteHeader(
                nombre: cliente.nombre,
                telefono: cliente.telefono,
                tieneUbicacion: cliente.tieneUbicacion,
                latitud: cliente.latitud,
                longitud: cliente.longitud,
              ),
              _ClienteInfo(cliente: cliente),
              const SizedBox(height: 8),
              _ContratosSection(
                clienteId: widget.clienteId,
                esAdmin: esAdmin,
                enAdminShell: enAdminShell,
              ),
              const SizedBox(height: 8),
              _CuotasSection(
                  clienteId: widget.clienteId,
                  diasGracia: diasGracia,
                  onSelectionChanged: (sel) =>
                      setState(() => _selectedCuotas = sel),
              ),
              const SizedBox(height: 8),
              _PagosSection(clienteId: widget.clienteId),
              const SizedBox(height: 8),
              _VisitasSection(key: _visitasKey, clienteId: widget.clienteId),
            ],
          );
        },
      ),
    );
  }

  Future<void> _mostrarDialogVisita(BuildContext context) async {
    final resultado =
        await showDialog<({VisitaResultado resultado, String? notas})>(
      context: context,
      builder: (_) => const _RegistrarVisitaDialog(),
    );
    if (resultado == null || !context.mounted) return;

    final service = ref.read(visitasServiceProvider);
    await service.registrar(
      clienteId: widget.clienteId,
      resultado: resultado.resultado,
      notas: resultado.notas,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Visita registrada')),
      );
      // Fuerza recarga de la sección de visitas via GlobalKey.
      _visitasKey.currentState?.recargar();
    }
  }
}

class _ClienteHeader extends StatelessWidget {
  const _ClienteHeader({
    required this.nombre,
    required this.telefono,
    required this.tieneUbicacion,
    required this.latitud,
    required this.longitud,
  });
  final String nombre;
  final String? telefono;
  final bool tieneUbicacion;
  final double? latitud;
  final double? longitud;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(nombre, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (telefono != null && telefono!.isNotEmpty) ...[
                _IconButton(
                  icon: Icons.phone,
                  label: 'Llamar',
                  onTap: () => ExternalActions.llamar(context, telefono!),
                ),
                _IconButton(
                  icon: Icons.chat,
                  label: 'WhatsApp',
                  onTap: () => ExternalActions.whatsapp(context, telefono!),
                ),
              ],
              if (tieneUbicacion)
                _IconButton(
                  icon: Icons.directions,
                  label: 'Navegar',
                  onTap: () => ExternalActions.navegarA(
                    context,
                    lat: latitud!,
                    lng: longitud!,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: onTap,
    );
  }
}

class _ClienteInfo extends StatelessWidget {
  const _ClienteInfo({required this.cliente});
  final dynamic cliente;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(context, Icons.badge, 'Cédula', cliente.cedula),
              _row(context, Icons.phone, 'Teléfono', cliente.telefono),
              _row(context, Icons.home, 'Dirección', cliente.direccion),
              _row(context, Icons.location_on, 'Referencia',
                  cliente.direccionReferencia),
              if (cliente.tieneUbicacion)
                _row(context, Icons.gps_fixed, 'GPS',
                    '${cliente.latitud!.toStringAsFixed(5)}, ${cliente.longitud!.toStringAsFixed(5)}'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          SizedBox(width: 90, child: Text(label, style: TextStyle(color: scheme.outline))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sección de contratos del cliente
// ─────────────────────────────────────────────────────────────────────────────

class _ContratosSection extends StatefulWidget {
  const _ContratosSection({
    required this.clienteId,
    required this.esAdmin,
    required this.enAdminShell,
  });
  final String clienteId;
  final bool esAdmin;
  final bool enAdminShell;

  @override
  State<_ContratosSection> createState() => _ContratosSectionState();
}

class _ContratosSectionState extends State<_ContratosSection> {
  late Stream<List<Map<String, dynamic>>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ps.db.watch(
      '''
      SELECT ct.*, p.nombre AS plan_nombre, p.precio_mensual,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id) AS total_cuotas,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado IN ('pendiente','parcial')) AS cuotas_pendientes,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado = 'pagada') AS cuotas_pagadas,
             (SELECT COUNT(*) FROM cuotas WHERE contrato_id = ct.id
              AND estado IN ('pendiente','parcial')
              AND fecha_vencimiento < date('now')) AS cuotas_vencidas
        FROM contratos ct
   LEFT JOIN planes p ON p.id = ct.plan_id
       WHERE ct.cliente_id = ?
       ORDER BY ct.activo DESC, ct.created_at DESC
      ''',
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: ${snap.error}'),
            ));
          }
          final rows = snap.data!;
          final activos = rows.where((r) => (r['activo'] as int? ?? 1) == 1).toList();
          final cancelados = rows.where((r) => (r['activo'] as int? ?? 1) != 1).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Text('Contratos',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Text('(${activos.length} activo${activos.length != 1 ? 's' : ''})',
                      style: TextStyle(color: scheme.outline, fontSize: 13)),
                  const Spacer(),
                  if (widget.esAdmin)
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Nuevo'),
                      onPressed: () {
                        final path = widget.enAdminShell
                            ? '/admin/contratos/nuevo?cliente_id=${widget.clienteId}'
                            : '/contratos/nuevo?cliente_id=${widget.clienteId}';
                        context.push(path);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Contratos activos
              if (activos.isEmpty && cancelados.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('Sin contratos',
                          style: TextStyle(color: scheme.outline)),
                    ),
                  ),
                ),

              ...activos.map((ct) => _ContratoCard(
                    contrato: ct,
                    esAdmin: widget.esAdmin,
                    onTap: () {
                      // Sprint 3: navegar al detalle del contrato
                      // Por ahora no hay pantalla de detalle del contrato
                    },
                  )),

              // Contratos cancelados (colapsable)
              if (cancelados.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  title: Text('Contratos cancelados (${cancelados.length})',
                      style: TextStyle(color: scheme.outline, fontSize: 14)),
                  initiallyExpanded: false,
                  children: cancelados
                      .map((ct) => _ContratoCard(
                            contrato: ct,
                            esAdmin: widget.esAdmin,
                            cancelado: true,
                            onTap: () {},
                          ))
                      .toList(),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ContratoCard extends StatelessWidget {
  const _ContratoCard({
    required this.contrato,
    required this.esAdmin,
    this.cancelado = false,
    required this.onTap,
  });
  final Map<String, dynamic> contrato;
  final bool esAdmin;
  final bool cancelado;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = contrato['plan_nombre'] as String? ?? 'Sin plan';
    final precio = (contrato['precio_mensual'] as num?)?.toDouble() ?? 0;
    final totalCuotas = (contrato['total_cuotas'] as num?)?.toInt() ?? 0;
    final pagadas = (contrato['cuotas_pagadas'] as num?)?.toInt() ?? 0;
    final vencidas = (contrato['cuotas_vencidas'] as num?)?.toInt() ?? 0;
    final pendientes = (contrato['cuotas_pendientes'] as num?)?.toInt() ?? 0;

    return Card(
      color: cancelado ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : null,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.description,
                      color: cancelado ? scheme.outline : scheme.primary,
                      size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(plan,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: cancelado ? TextDecoration.lineThrough : null,
                        )),
                  ),
                  Text(Fmt.cordobas(precio) + '/mes',
                      style: TextStyle(
                        color: scheme.outline,
                        fontSize: 12,
                      )),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text('$pagadas/$totalCuotas pagadas',
                      style: TextStyle(color: scheme.outline, fontSize: 12)),
                  if (vencidas > 0)
                    Text('$vencidas vencida${vencidas != 1 ? 's' : ''}',
                        style: TextStyle(
                          color: scheme.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        )),
                  if (vencidas == 0 && pendientes > 0)
                    Text('Al día',
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 12,
                        )),
                  if (pendientes == 0 && totalCuotas > 0)
                    Text('Completado ✓',
                        style: TextStyle(
                          color: scheme.tertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sección de cuotas (manuales)
// ─────────────────────────────────────────────────────────────────────────────

class _CuotasSection extends StatefulWidget {
  const _CuotasSection({
    required this.clienteId,
    required this.diasGracia,
    required this.onSelectionChanged,
  });
  final String clienteId;
  final int diasGracia;
  final ValueChanged<Set<String>> onSelectionChanged;

  @override
  State<_CuotasSection> createState() => _CuotasSectionState();
}

class _CuotasSectionState extends State<_CuotasSection> {
  late Stream<List<Map<String, dynamic>>> _cuotasStream;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _cuotasStream = _buildStream();
  }

  @override
  void didUpdateWidget(covariant _CuotasSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() {
        _cuotasStream = _buildStream();
        _selected.clear();
      });
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT cu.*, p.nombre AS plan_nombre, p.precio_mensual
        FROM cuotas cu
        LEFT JOIN contratos ct ON ct.id = cu.contrato_id
        LEFT JOIN planes p     ON p.id = ct.plan_id
       WHERE cu.cliente_id = ?
       ORDER BY cu.periodo ASC
      ''',
      parameters: [widget.clienteId],
    );
  }

  void _toggleSelect(String cuotaId, List<String> pendingIds) {
    setState(() {
      if (_selected.contains(cuotaId)) {
        // Al deseleccionar, quitar este y todos los posteriores.
        final idx = pendingIds.indexOf(cuotaId);
        for (var i = idx; i < pendingIds.length; i++) {
          _selected.remove(pendingIds[i]);
        }
      } else {
        // Solo permitir seleccionar si es el siguiente en la secuencia.
        final idx = pendingIds.indexOf(cuotaId);
        if (idx == 0 || _selected.contains(pendingIds[idx - 1])) {
          _selected.add(cuotaId);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Debés cobrar las cuotas anteriores primero'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    });
    widget.onSelectionChanged(Set.of(_selected));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _cuotasStream,
        initialData: const [],
        builder: (context, snap) {
          if (snap.hasError) {
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Error: ${snap.error}'),
              ),
            );
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No hay cuotas todavía',
                    textAlign: TextAlign.center),
              ),
            );
          }

          final total = rows.length;
          final pagadas = rows.where((r) => r['estado'] == 'pagada').length;
          final pendientes = rows.where((r) {
            final e = r['estado'] as String;
            return e == 'pendiente' || e == 'parcial';
          }).toList();
          final pendingIds = pendientes.map((r) => r['id'] as String).toList();
          final montoTotal = rows.fold<double>(
              0, (s, r) => s + (r['monto'] as num).toDouble());
          final montoPendiente = pendientes.fold<double>(
              0, (s, r) => s + (r['monto'] as num).toDouble() -
                  (r['monto_pagado'] as num? ?? 0).toDouble());

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text('Cuotas',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Wrap(
                        spacing: 16,
                        children: [
                          Text('$pagadas/$total pagadas',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                                fontSize: 12,
                              )),
                          Text('Contrato: ${Fmt.cordobas(montoTotal)}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                                fontSize: 12,
                              )),
                          if (montoPendiente > 0)
                            Text('Pendiente: ${Fmt.cordobas(montoPendiente)}',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                )),
                        ],
                      ),
                    ),
                    ...rows.map((r) {
                      final cuota = Cuota.fromRow(r);
                      final isPending = pendingIds.contains(cuota.id);
                      final isSelected = _selected.contains(cuota.id);
                      return _CuotaTile(
                        cuota: cuota,
                        planNombre: r['plan_nombre'] as String?,
                        diasGracia: widget.diasGracia,
                        showCheckbox: _selected.isNotEmpty && isPending,
                        isSelected: isSelected,
                        onSelect: isPending
                            ? () => _toggleSelect(cuota.id, pendingIds)
                            : null,
                      );
                    }),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }
}

class _CuotaTile extends StatelessWidget {
  const _CuotaTile({
    required this.cuota,
    required this.planNombre,
    required this.diasGracia,
    this.showCheckbox = false,
    this.isSelected = false,
    this.onSelect,
  });

  final Cuota cuota;
  final String? planNombre;
  final int diasGracia;
  final bool showCheckbox;
  final bool isSelected;
  final VoidCallback? onSelect;

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
    final estadoVisual = cuota.estadoVisual(diasGracia);
    final color = switch (estadoVisual) {
      CuotaEstadoVisual.pagada => scheme.tertiary,
      CuotaEstadoVisual.parcial => scheme.secondary,
      CuotaEstadoVisual.enGracia => Colors.amber.shade700,
      CuotaEstadoVisual.vencida => scheme.error,
      CuotaEstadoVisual.anulada => scheme.outline,
      _ => scheme.primary,
    };

    return ListTile(
      selected: isSelected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.3),
      leading: showCheckbox
          ? Checkbox(value: isSelected, onChanged: (_) => onSelect?.call())
          : CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(
                estadoVisual == CuotaEstadoVisual.pagada
                    ? Icons.check
                    : estadoVisual == CuotaEstadoVisual.vencida
                        ? Icons.warning
                        : Icons.receipt_long,
                color: color,
              ),
            ),
      title: Row(
        children: [
          Expanded(
            child: Text('${Fmt.mes(cuota.periodo)[0].toUpperCase()}${Fmt.mes(cuota.periodo).substring(1)}'),
          ),
          if (cuota.esManual) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('Manual',
                  style: TextStyle(fontSize: 9, color: scheme.onTertiaryContainer)),
            ),
            if (cuota.tipoCargoManual != null) ...[
              const SizedBox(width: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _tipoLabel(cuota.tipoCargoManual!),
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
          Text(planNombre ?? cuota.descripcion ?? '—',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('Vence ${Fmt.fechaCorta(cuota.fechaVencimiento)} · ${estadoVisual.label}',
              style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Fmt.cordobas(cuota.monto),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (cuota.saldo < cuota.monto && cuota.saldo > 0)
            Text('Saldo: ${Fmt.cordobas(cuota.saldo)}',
                style: TextStyle(color: scheme.outline, fontSize: 11)),
        ],
      ),
      onTap: estadoVisual.esCobrable
          ? (onSelect ?? () => context.push('/cobro/${cuota.id}'))
          : null,
      onLongPress: onSelect,
    );
  }
}

class _PagosSection extends StatefulWidget {
  const _PagosSection({required this.clienteId});
  final String clienteId;

  @override
  State<_PagosSection> createState() => _PagosSectionState();
}

// ── Sprint D1: Registrar visita dialog + historial de visitas ──────────

class _RegistrarVisitaDialog extends StatefulWidget {
  const _RegistrarVisitaDialog();

  @override
  State<_RegistrarVisitaDialog> createState() => _RegistrarVisitaDialogState();
}

class _RegistrarVisitaDialogState extends State<_RegistrarVisitaDialog> {
  VisitaResultado _resultado = VisitaResultado.noEstaba;
  final _notasCtrl = TextEditingController();

  @override
  void dispose() {
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar visita'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<VisitaResultado>(
            value: _resultado,
            decoration: const InputDecoration(
              labelText: 'Resultado',
              border: OutlineInputBorder(),
            ),
            items: VisitaResultado.values
                .map((r) => DropdownMenuItem(value: r, child: Text(r.label)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _resultado = v);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notasCtrl,
            decoration: const InputDecoration(
              labelText: 'Notas (opcional)',
              hintText: 'Ej: promete pagar el viernes',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (
              resultado: _resultado,
              notas: _notasCtrl.text.trim().isEmpty
                  ? null
                  : _notasCtrl.text.trim(),
            ),
          ),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

class _VisitasSection extends StatefulWidget {
  const _VisitasSection({super.key, required this.clienteId});
  final String clienteId;

  @override
  State<_VisitasSection> createState() => _VisitasSectionState();
}

class _VisitasSectionState extends State<_VisitasSection> {
  late Future<List<Visita>> _visitasFuture;
  final _service = VisitasService();

  @override
  void initState() {
    super.initState();
    _visitasFuture = _service.listar(widget.clienteId);
  }

  @override
  void didUpdateWidget(covariant _VisitasSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() => _visitasFuture = _service.listar(widget.clienteId));
    }
  }

  /// Permite al parent forzar un rebuild (tras registrar una visita nueva).
  void recargar() {
    setState(() => _visitasFuture = _service.listar(widget.clienteId));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: FutureBuilder<List<Visita>>(
          future: _visitasFuture,
          builder: (context, snap) {
            final visitas = snap.data ?? const [];
            if (visitas.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text('Visitas recientes',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                ...visitas.take(10).map((v) => _VisitaTile(visita: v)),
                if (visitas.length > 10)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${visitas.length - 10} visita(s) más antiguas',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _VisitaTile extends StatelessWidget {
  const _VisitaTile({required this.visita});
  final Visita visita;

  IconData get _icon => switch (visita.resultado) {
        VisitaResultado.cobrado => Icons.check_circle,
        VisitaResultado.noEstaba => Icons.person_off,
        VisitaResultado.sinPago => Icons.money_off,
        VisitaResultado.promesaPago => Icons.handshake,
        VisitaResultado.otro => Icons.notes,
      };

  Color _color(ColorScheme scheme) => switch (visita.resultado) {
        VisitaResultado.cobrado => scheme.tertiary,
        VisitaResultado.noEstaba => scheme.outline,
        VisitaResultado.sinPago => scheme.error,
        VisitaResultado.promesaPago => scheme.secondary,
        VisitaResultado.otro => scheme.outline,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(scheme);
    return ListTile(
      dense: true,
      leading: Icon(_icon, color: color, size: 20),
      title: Text(visita.resultado.label),
      subtitle: visita.notas != null && visita.notas!.isNotEmpty
          ? Text(visita.notas!, maxLines: 2, overflow: TextOverflow.ellipsis)
          : null,
      trailing: Text(
        Fmt.fechaRelativa(visita.fecha),
        style: TextStyle(color: scheme.outline, fontSize: 11),
      ),
    );
  }
}

// ── Fin Sprint D1 ──────────────────────────────────────────────────────

class _PagosSectionState extends State<_PagosSection> {
  late Stream<List<Map<String, dynamic>>> _pagosStream;

  @override
  void initState() {
    super.initState();
    _pagosStream = _buildStream();
  }

  @override
  void didUpdateWidget(covariant _PagosSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() => _pagosStream = _buildStream());
    }
  }

  Stream<List<Map<String, dynamic>>> _buildStream() {
    return ps.db.watch(
      '''
      SELECT p.id, p.monto_cordobas, p.moneda, p.monto_original,
             p.metodo, p.fecha_pago, p.referencia,
             cu.periodo
        FROM pagos p
        JOIN cuotas cu ON cu.id = p.cuota_id
       WHERE cu.cliente_id = ?
       ORDER BY p.fecha_pago DESC
       LIMIT 10
      ''',
      parameters: [widget.clienteId],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _pagosStream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: ${snap.error}'),
              );
            }
            final rows = snap.data!;
            if (rows.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text('Últimos pagos',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                ...rows.map((r) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.payments_outlined),
                      title: Text(Fmt.cordobas(r['monto_cordobas'] as num)),
                      subtitle: Text(
                        '${MetodoPago.fromString(r['metodo'] as String).label} · ${Fmt.fechaCorta(DateTime.parse(r['fecha_pago'] as String))}',
                      ),
                      trailing: (r['moneda'] as String) == 'USD'
                          ? Text('US\$${(r['monto_original'] as num).toStringAsFixed(2)}',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.outline))
                          : null,
                    )),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}
