import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/cobrador_admin.dart';
import '../../data/models/modulo.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/empty_state.dart';

/// Detalle de un tenant: toggles de módulos. Cada switch llama
/// set_tenant_modulo() vía RPC y refresca la lista global.
class TenantModulosScreen extends ConsumerWidget {
  const TenantModulosScreen({super.key, required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenantsAsync = ref.watch(tenantsAdminProvider);
    final modulosAsync = ref.watch(modulosProvider);

    if (tenantsAsync.isLoading || modulosAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tenantsAsync.hasError) {
      return Center(child: Text('Error: ${tenantsAsync.error}'));
    }
    if (modulosAsync.hasError) {
      return Center(child: Text('Error: ${modulosAsync.error}'));
    }

    final tenant = tenantsAsync.value!.where((t) => t.id == tenantId).firstOrNull;
    final modulos = modulosAsync.value!;

    if (tenant == null) {
      return const Center(child: Text('Tenant no encontrado'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Header(tenant: tenant),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.person_add),
            label: const Text('Invitar admin a este tenant'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _InvitarAdminDialog(tenant: tenant),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Módulos',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Activá las funcionalidades que este tenant tiene contratadas.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 16),
        ...modulos.map((m) => _ModuloTile(
              tenant: tenant,
              modulo: m,
            )),
        const SizedBox(height: 32),
        Text('Miembros del tenant',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Usuarios con acceso a este tenant.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 16),
        _MiembrosList(tenantId: tenant.id),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.tenant});
  final TenantAdmin tenant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              radius: 28,
              child: Text(
                _initials(tenant.nombre),
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tenant.nombre,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${tenant.cobradoresCount} cobradores activos',
                    style: TextStyle(color: scheme.outline),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    tenant.id,
                    style: TextStyle(
                      color: scheme.outline,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

class _ModuloTile extends ConsumerStatefulWidget {
  const _ModuloTile({required this.tenant, required this.modulo});

  final TenantAdmin tenant;
  final Modulo modulo;

  @override
  ConsumerState<_ModuloTile> createState() => _ModuloTileState();
}

class _ModuloTileState extends ConsumerState<_ModuloTile> {
  bool _saving = false;

  Future<void> _toggle(bool value) async {
    setState(() => _saving = true);
    try {
      await ref.read(superAdminRepoProvider).setTenantModulo(
            tenantId: widget.tenant.id,
            modulo: widget.modulo.codigo,
            habilitado: value,
          );
      ref.invalidate(tenantsAdminProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Módulo ${widget.modulo.nombre} ${value ? "habilitado" : "deshabilitado"}'),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.modulo;
    final habilitado = widget.tenant.tieneModulo(m.codigo);
    final scheme = Theme.of(context).colorScheme;
    final esBase = m.esBase;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(m.nombre,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      if (esBase) ...[
                        const SizedBox(width: 8),
                        Chip(
                          label: const Text('Base',
                              style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: scheme.tertiaryContainer,
                          labelStyle: TextStyle(
                            color: scheme.onTertiaryContainer,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (m.descripcion != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      m.descripcion!,
                      style: TextStyle(
                          color: scheme.outline, fontSize: 13),
                    ),
                  ],
                  if (esBase) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Módulo base, no se puede deshabilitar.',
                      style: TextStyle(
                          color: scheme.outline,
                          fontSize: 12,
                          fontStyle: FontStyle.italic),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (_saving)
              const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Switch.adaptive(
                value: habilitado,
                onChanged: esBase || _saving ? null : _toggle,
              ),
          ],
        ),
      ),
    );
  }
}

/// Lista de miembros (cobradores) de un tenant. Lee de la RPC
/// `list_cobradores_tenant`.
class _MiembrosList extends ConsumerWidget {
  const _MiembrosList({required this.tenantId});

  final String tenantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(cobradoresTenantProvider(tenantId));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 8),
              const Text('No se pudo cargar la lista de miembros',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                onPressed: () =>
                    ref.invalidate(cobradoresTenantProvider(tenantId)),
              ),
            ],
          ),
        ),
      ),
      data: (miembros) {
        if (miembros.isEmpty) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: EmptyState(
                icon: Icons.person_off,
                titulo: 'Sin miembros',
                descripcion:
                    'Usá "Invitar admin a este tenant" para agregar el primero.',
              ),
            ),
          );
        }
        return Column(
          children: miembros
              .map((c) => _MiembroCard(cobrador: c, tenantId: tenantId))
              .toList(),
        );
      },
    );
  }
}

/// Acciones disponibles en el menú "..." de cada miembro.
/// Por ahora sólo activar/desactivar — el resto (reset password,
/// cambiar rol, etc.) se agregan en pasos siguientes.
enum _AccionMiembro { toggleActivo }

class _MiembroCard extends ConsumerStatefulWidget {
  const _MiembroCard({required this.cobrador, required this.tenantId});

  final CobradorAdmin cobrador;
  final String tenantId;

  @override
  ConsumerState<_MiembroCard> createState() => _MiembroCardState();
}

class _MiembroCardState extends ConsumerState<_MiembroCard> {
  bool _saving = false;

  Future<void> _ejecutarAccion(_AccionMiembro accion) async {
    switch (accion) {
      case _AccionMiembro.toggleActivo:
        await _toggleActivo();
    }
  }

  Future<void> _toggleActivo() async {
    final c = widget.cobrador;
    final scheme = Theme.of(context).colorScheme;
    // Estado al que estamos pasando, capturado antes del await para que el
    // snackbar lea el valor correcto aún si el widget se reconstruye con
    // datos frescos del provider.
    final nuevoEstado = !c.activo;

    // Capturamos container y messenger antes de cualquier await — el
    // SnackBarAction sobrevive al rebuild del widget tras la invalidación
    // de providers, y si usamos `ref` del state, el callback de Deshacer
    // puede correr cuando el state ya no es válido y tira en silencio.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final tenantId = widget.tenantId;
    final repo = container.read(superAdminRepoProvider);

    if (c.activo) {
      // Detectar si es el último admin activo del tenant para advertir
      // — no bloqueamos (super_admin tiene el poder) pero avisamos.
      final miembros =
          ref.read(cobradoresTenantProvider(widget.tenantId)).valueOrNull ??
              const [];
      final adminsActivos = miembros
          .where((m) => m.rol == 'admin' && m.activo && m.id != c.id)
          .length;
      final esUltimoAdmin = c.rol == 'admin' && adminsActivos == 0;

      final confirmar = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) {
          final dialogScheme = Theme.of(dialogCtx).colorScheme;
          return AlertDialog(
            title: Text('¿Desactivar a ${c.nombre}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El usuario no podrá iniciar sesión. Sus datos históricos '
                  '(pagos, recibos, auditoría) se conservan y podés '
                  'reactivarlo más tarde sin pérdida.',
                ),
                if (esUltimoAdmin) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: dialogScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber,
                            color: dialogScheme.onErrorContainer, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Atención: es el único admin activo del tenant. '
                            'Tras desactivarlo, nadie podrá administrar este '
                            'ISP hasta que reactives a alguien o invites '
                            'otro admin.',
                            style: TextStyle(
                                color: dialogScheme.onErrorContainer,
                                fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogCtx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: dialogScheme.error,
                  foregroundColor: dialogScheme.onError,
                ),
                onPressed: () => Navigator.of(dialogCtx).pop(true),
                child: const Text('Desactivar'),
              ),
            ],
          );
        },
      );
      if (confirmar != true) return;
    }

    setState(() => _saving = true);
    try {
      await repo.setCobradorActivo(
        cobradorId: c.id,
        activo: nuevoEstado,
      );
      container.invalidate(cobradoresTenantProvider(tenantId));
      container.invalidate(tenantsAdminProvider);
      if (!mounted) return;
      final accionPasada = nuevoEstado ? 'activado' : 'desactivado';
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('${c.nombre} $accionPasada'),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: () async {
              try {
                await repo.setCobradorActivo(
                  cobradorId: c.id,
                  activo: !nuevoEstado,
                );
                container.invalidate(cobradoresTenantProvider(tenantId));
                container.invalidate(tenantsAdminProvider);
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text(
                      '${c.nombre} '
                      '${!nuevoEstado ? "activado" : "desactivado"} '
                      '(deshacer)',
                    ),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } catch (e) {
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text('No se pudo deshacer: $e'),
                    backgroundColor: scheme.error,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Muestra una SnackBar y fuerza el cierre tras `duration` con un Timer
  /// manual. Flutter web tiene un bug conocido donde el MouseRegion interno
  /// del SnackBar mantiene el hover en true permanentemente cuando el
  /// snackbar contiene un action, lo que pausa el auto-dismiss. Cerramos
  /// nosotros por las dudas — si ya se cerró por otra vía, close() es no-op.
  static void _mostrarSnackBar(
    ScaffoldMessengerState messenger,
    SnackBar bar,
  ) {
    final controller = messenger.showSnackBar(bar);
    Timer(bar.duration, () {
      try {
        controller.close();
      } catch (_) {/* controller ya cerrado */}
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cobrador;
    final scheme = Theme.of(context).colorScheme;
    final rolColor = _rolColor(scheme, c.rol);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: c.activo
                  ? rolColor.withValues(alpha: 0.15)
                  : scheme.surfaceContainerHighest,
              foregroundColor: c.activo ? rolColor : scheme.outline,
              child: Text(
                _initials(c.nombre),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Nombre + chip de rol en Wrap, no Row, para evitar
                  // overflow en pantallas angostas.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        c.nombre,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      _RolChip(rol: c.rol),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.email ?? '(sin email)',
                    style: TextStyle(color: scheme.outline, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _EstadoChip(cobrador: c),
                      Text(
                        _ultimoLoginLabel(c),
                        style: TextStyle(color: scheme.outline, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Menú de acciones a la derecha. Mostramos spinner mientras una
            // acción está corriendo para evitar dobles clicks.
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              PopupMenuButton<_AccionMiembro>(
                tooltip: 'Acciones para ${c.nombre}',
                onSelected: _ejecutarAccion,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _AccionMiembro.toggleActivo,
                    child: Row(
                      children: [
                        Icon(
                          c.activo ? Icons.block : Icons.check_circle,
                          color: c.activo ? scheme.error : scheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(c.activo ? 'Desactivar' : 'Activar'),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  static Color _rolColor(ColorScheme s, String rol) => switch (rol) {
        'super_admin' => s.tertiary,
        'admin' => s.primary,
        'admin_cobranza' => s.secondary,
        _ => s.onSurfaceVariant,
      };

  static String _ultimoLoginLabel(CobradorAdmin c) {
    if (c.lastSignInAt == null) return 'Nunca inició sesión';
    // Guard contra clock skew (device atrás del server): nunca mostramos
    // "hace -1 días". Si la diferencia es negativa o cero → "hoy".
    final raw = DateTime.now().difference(c.lastSignInAt!).inDays;
    final dias = raw < 0 ? 0 : raw;
    if (dias == 0) return 'Última sesión: hoy';
    if (dias == 1) return 'Última sesión: ayer';
    if (dias < 30) return 'Última sesión: hace $dias días';
    return 'Última sesión: ${Fmt.fechaLarga(c.lastSignInAt!)}';
  }
}

class _RolChip extends StatelessWidget {
  const _RolChip({required this.rol});
  final String rol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (rol) {
      'super_admin' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'admin' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'admin_cobranza' =>
        (scheme.secondaryContainer, scheme.onSecondaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    final label = switch (rol) {
      'super_admin' => 'Super Admin',
      'admin' => 'Administrador',
      'admin_cobranza' => 'Admin de cobranza',
      'cobrador' => 'Cobrador',
      _ => rol,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class _EstadoChip extends StatelessWidget {
  const _EstadoChip({required this.cobrador});
  final CobradorAdmin cobrador;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Cada estado tiene un ícono distinto (no se diferencia sólo por color,
    // por accesibilidad WCAG 1.4.1).
    final (label, icon, bg, fg) = !cobrador.activo
        ? (
            'Inactivo',
            Icons.block,
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
          )
        : cobrador.invitacionPendiente
            ? (
                'Invitación pendiente',
                Icons.schedule_send,
                scheme.surfaceContainerHighest,
                scheme.onSurfaceVariant,
              )
            : (
                'Activo',
                Icons.check_circle,
                scheme.primaryContainer,
                scheme.onPrimaryContainer,
              );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Dialog para que el super_admin invite el primer/otro admin de un tenant.
/// Llama a la Edge Function `invitar-cobrador` con tenant_id explícito.
class _InvitarAdminDialog extends ConsumerStatefulWidget {
  const _InvitarAdminDialog({required this.tenant});
  final TenantAdmin tenant;

  @override
  ConsumerState<_InvitarAdminDialog> createState() =>
      _InvitarAdminDialogState();
}

class _InvitarAdminDialogState extends ConsumerState<_InvitarAdminDialog> {
  final _email = TextEditingController();
  final _nombre = TextEditingController();
  final _telefono = TextEditingController();
  bool _enviando = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _nombre.dispose();
    _telefono.dispose();
    super.dispose();
  }

  Future<void> _invitar() async {
    final email = _email.text.trim();
    final nombre = _nombre.text.trim();
    if (email.isEmpty || nombre.isEmpty) {
      setState(() => _error = 'Email y nombre requeridos');
      return;
    }
    if (!RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(email)) {
      setState(() => _error = 'Email inválido');
      return;
    }

    setState(() {
      _enviando = true;
      _error = null;
    });

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'invitar-cobrador',
        body: {
          'email': email,
          'nombre': nombre,
          'rol': 'admin',
          'tenant_id': widget.tenant.id,
          if (_telefono.text.trim().isNotEmpty)
            'telefono': _telefono.text.trim(),
        },
      );
      final data = res.data as Map<String, dynamic>?;
      if (data == null || data['ok'] != true) {
        setState(() {
          _error = (data?['error'] as String?) ?? 'Error desconocido';
          _enviando = false;
        });
        return;
      }
      // Refrescar lista de tenants (cobradores_count) y lista de miembros
      // para que aparezca el nuevo invitado con estado "pendiente".
      ref.invalidate(tenantsAdminProvider);
      ref.invalidate(cobradoresTenantProvider(widget.tenant.id));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Invitación enviada a $email'),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _enviando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Invitar admin a ${widget.tenant.nombre}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'El invitado recibirá un email para crear su contraseña. '
              'Una vez logueado, será admin de este tenant.',
              style: TextStyle(color: scheme.outline, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'admin@empresa.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nombre,
              decoration: const InputDecoration(
                labelText: 'Nombre completo',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telefono,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Teléfono (opcional)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: _enviando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          label: const Text('Enviar invitación'),
          onPressed: _enviando ? null : _invitar,
        ),
      ],
    );
  }
}
