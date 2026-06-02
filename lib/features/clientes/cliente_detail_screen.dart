import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers/cobrador_provider.dart';
import '../../data/providers/impersonation_provider.dart';
import '../../data/repositories/clientes_repo.dart';
import '../../data/services/external_actions.dart';
import '../../data/services/visitas_service.dart';
import '../../data/utils/formatters.dart';
import '../../powersync/db.dart' as ps;
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/foto_gallery_widget.dart';
import '../shared/widgets/impersonation_banner.dart';
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

  void _showHistorial(BuildContext context) {
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
                child: HistorialClienteWidget(clienteId: widget.clienteId),
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
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final impersonando = ref.watch(estaImpersonandoProvider);
    final esAdmin = cobrador?.tieneAccesoAdmin ?? false;
    // El change-log / auditoría se oculta al cobrador puro (least-privilege:
    // si el rol aún no cargó → null → oculto). admin/admin_cobranza/super sí.
    final verHistorial = cobrador != null && !cobrador.esCobrador;
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
          if (verHistorial)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Historial de cambios',
              onPressed: () => _showHistorial(context),
            ),
        ],
      ),
      // FAB oculto impersonando (#9): la visita se atribuiría al tenant System.
      floatingActionButton: clienteAsync.valueOrNull != null && !impersonando
          ? FloatingActionButton.extended(
              onPressed: () => _mostrarDialogVisita(context),
              icon: const Icon(Icons.add_task),
              label: const Text('Registrar visita'),
            )
          : null,
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
          // Aprovechar espacio en pantallas grandes: maxWidth 1100,
          // centrado. Mobile usa todo el ancho disponible.
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 80),
                children: [
                  const ImpersonationBanner(), // #9a
                  _ClienteHeader(
                    codigo: cliente.codigo,
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
                    clienteCobradorId: cliente.cobradorId,
                    esAdmin: esAdmin,
                    enAdminShell: enAdminShell,
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FotoGalleryWidget(
                      clienteId: widget.clienteId,
                      tenantId: cliente.tenantId,
                      canEdit: esAdmin || (cobrador?.esAdminCobranza ?? false),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _VisitasSection(key: _visitasKey, clienteId: widget.clienteId),
                ],
              ),
            ),
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
    try {
      await service.registrar(
        clienteId: widget.clienteId,
        resultado: resultado.resultado,
        notas: resultado.notas,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Visita registrada')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al registrar visita: $e')),
        );
      }
    }
  }
}

class _ClienteHeader extends StatelessWidget {
  const _ClienteHeader({
    required this.codigo,
    required this.nombre,
    required this.telefono,
    required this.tieneUbicacion,
    required this.latitud,
    required this.longitud,
  });
  final String? codigo;
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
          if (codigo != null)
            Text(codigo!,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      letterSpacing: 0.5,
                    )),
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
    required this.clienteCobradorId,
    required this.esAdmin,
    required this.enAdminShell,
  });
  final String clienteId;
  final String? clienteCobradorId;
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
              AND fecha_vencimiento < date('now', '-6 hours')) AS cuotas_vencidas
        FROM contratos ct
   LEFT JOIN planes p ON p.id = ct.plan_id
       WHERE ct.cliente_id = ?
       ORDER BY ct.estado ASC, ct.created_at DESC
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
          final activos = rows.where((r) => (r['estado'] as String? ?? 'activo') == 'activo').toList();
          final cancelados = rows.where((r) => (r['estado'] as String? ?? 'activo') != 'activo').toList();

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
                    Tooltip(
                      message: widget.clienteCobradorId == null
                          ? 'Asigna un cobrador al cliente antes de crear contratos'
                          : '',
                      child: TextButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Nuevo'),
                        onPressed: widget.clienteCobradorId == null
                            ? null
                            : () {
                                final path = widget.enAdminShell
                                    ? '/admin/contratos/nuevo?cliente_id=${widget.clienteId}'
                                    : '/contratos/nuevo?cliente_id=${widget.clienteId}';
                                context.push(path);
                              },
                      ),
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
                      final id = ct['id'] as String;
                      final prefix = widget.enAdminShell ? '/admin' : '';
                      context.push('$prefix/contratos/$id');
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
                            onTap: () {
                              final id = ct['id'] as String;
                              final prefix = widget.enAdminShell ? '/admin' : '';
                              context.push('$prefix/contratos/$id');
                            },
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
    final codigo = contrato['codigo'] as String?;
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
              if (codigo != null && codigo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(codigo,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                          letterSpacing: 0.5)),
                ),
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

class _VisitasSection extends ConsumerStatefulWidget {
  const _VisitasSection({super.key, required this.clienteId});
  final String clienteId;

  @override
  ConsumerState<_VisitasSection> createState() => _VisitasSectionState();
}

class _VisitasSectionState extends ConsumerState<_VisitasSection> {
  late Stream<List<Visita>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = ref.read(visitasServiceProvider).watch(widget.clienteId);
  }

  @override
  void didUpdateWidget(covariant _VisitasSection old) {
    super.didUpdateWidget(old);
    if (widget.clienteId != old.clienteId) {
      setState(() {
        _stream = ref.read(visitasServiceProvider).watch(widget.clienteId);
      });
    }
  }

  /// API compat con el código viejo — el stream ya emite cambios automáticamente,
  /// pero algunos callers llaman recargar() después de registrar visita.
  void recargar() {}

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: StreamBuilder<List<Visita>>(
          stream: _stream,
          initialData: const [],
          builder: (context, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: ${snap.error}'),
              );
            }
            final visitas = snap.data!;
            if (visitas.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.history,
                        size: 18,
                        color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 8),
                    Text('Sin visitas registradas',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline)),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Icon(Icons.history,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('Historial de visitas',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Text('(${visitas.length})',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 13)),
                    ],
                  ),
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
    final hasNotas = visita.notas != null && visita.notas!.isNotEmpty;
    final cobrador = visita.cobradorNombre ?? '—';
    return ListTile(
      dense: true,
      leading: Icon(_icon, color: color, size: 22),
      title: Row(
        children: [
          Text(visita.resultado.label,
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
          const SizedBox(width: 8),
          Flexible(
            child: Text('· $cobrador',
                style: TextStyle(color: scheme.outline, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${Fmt.fechaCorta(visita.fecha.toLocal())} · ${Fmt.fechaRelativa(visita.fecha.toLocal())}',
            style: TextStyle(color: scheme.outline, fontSize: 11),
          ),
          if (hasNotas) ...[
            const SizedBox(height: 4),
            Text(visita.notas!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

// ── Fin Sprint D1 ──────────────────────────────────────────────────────
