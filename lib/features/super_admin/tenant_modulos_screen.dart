import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/cobrador_admin.dart';
import '../../data/models/modulo.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/cobrador_helpers.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/animated_list_entry.dart';
import '../shared/widgets/chips.dart';
import '../shared/widgets/credenciales_dialog.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/skeleton.dart';

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
      // Skeleton de header + módulos + miembros para preservar el layout
      // mientras viene la data (en vez del spinner que flasheaba antes).
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          SkeletonCard(hasAvatar: true, hasChip: false, marginBottom: 16),
          SizedBox(height: 8),
          SkeletonList(count: 2, hasAvatar: false, hasChip: false),
          SizedBox(height: 16),
          SkeletonList(count: 2, hasAvatar: true, hasChip: true),
        ],
      );
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
                initialsFromName(tenant.nombre),
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
      // Skeleton: 2 cards mientras carga — preserva el layout y le da al
      // user la sensación de "ya está viniendo data".
      loading: () => const SkeletonList(
        count: 2,
        hasAvatar: true,
        hasChip: true,
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
              .asMap()
              .entries
              .map((e) => AnimatedListEntry(
                    // Key estable por id para que list shrink/grow no
                    // re-anime los items existentes.
                    key: ValueKey(e.value.id),
                    index: e.key,
                    child:
                        _MiembroCard(cobrador: e.value, tenantId: tenantId),
                  ))
              .toList(),
        );
      },
    );
  }
}

/// Acciones disponibles en el menú "..." de cada miembro.
/// Algunas son condicionales según el estado del miembro:
///   - resetPasswordEmail / forzarPassword: sólo si emailConfirmedAt != null
///   - reenviarInvitacion: sólo si invitacionPendiente
enum _AccionMiembro {
  toggleActivo,
  forzarPassword,
  resetPasswordEmail,
  reenviarInvitacion,
  cambiarRol,
  cambiarEmail,
  eliminar,
}

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
      case _AccionMiembro.forzarPassword:
        await _forzarPassword();
      case _AccionMiembro.resetPasswordEmail:
        await _resetPasswordEmail();
      case _AccionMiembro.reenviarInvitacion:
        await _reenviarInvitacion();
      case _AccionMiembro.cambiarRol:
        await _cambiarRol();
      case _AccionMiembro.cambiarEmail:
        await _cambiarEmail();
      case _AccionMiembro.eliminar:
        await _eliminar();
    }
  }

  Future<void> _cambiarEmail() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final repo = container.read(superAdminRepoProvider);

    final nuevo = await showDialog<String>(
      context: context,
      builder: (_) => _CambiarEmailDialog(
        nombre: c.nombre,
        emailActual: c.email ?? '(sin email)',
      ),
    );
    if (nuevo == null || nuevo.isEmpty || nuevo == c.email) return;

    setState(() => _saving = true);
    try {
      await repo.cambiarEmailCobrador(
        cobradorId: c.id,
        nuevoEmail: nuevo,
      );
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('${c.nombre}: email cambiado a $nuevo'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo cambiar el email: $msg'),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _eliminar() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    final repo = container.read(superAdminRepoProvider);

    final confirmado = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EliminarDialog(cobrador: c),
    );
    if (confirmado != true) return;

    setState(() => _saving = true);
    try {
      await repo.eliminarCobrador(cobradorId: c.id);
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      container.invalidate(tenantsAdminProvider);
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('${c.nombre} eliminado'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text(msg),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetPasswordEmail() async {
    final c = widget.cobrador;
    final email = c.email;
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (email == null) {
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: const Text(
            'Este usuario no tiene email registrado. No se puede mandar reset.',
          ),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final s = Theme.of(dialogCtx).colorScheme;
        return AlertDialog(
          title: Text('¿Mandar reset password a ${c.nombre}?'),
          content: SizedBox(
            width: dialogW,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Se le enviará un email a $email con un link para '
                  'definir una nueva contraseña.',
                ),
                const SizedBox(height: 12),
                _WarningBox(
                  icon: Icons.info_outline,
                  color: s.surfaceContainerHighest,
                  onColor: s.onSurfaceVariant,
                  texto: 'No abras el link en este browser: quedarías '
                      'logueado como ${c.nombre} y perderías tu sesión '
                      'de Super Admin.',
                ),
                if (!c.activo) ...[
                  const SizedBox(height: 12),
                  _WarningBox(
                    icon: Icons.warning_amber,
                    color: s.errorContainer,
                    onColor: s.onErrorContainer,
                    texto: '${c.nombre} está inactivo. Aunque resetee su '
                        'contraseña no va a poder iniciar sesión hasta '
                        'que lo reactives.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.mail_outline),
              label: const Text('Enviar email'),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmar != true) return;

    setState(() => _saving = true);
    final repo =
        ProviderScope.containerOf(context, listen: false)
            .read(superAdminRepoProvider);
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb ? '${Uri.base.origin}/?flow=recovery' : null,
      );
      // Audit log del intento. Fire-and-forget — si falla no rollback
      // (el email ya está en tránsito). Usamos developer.log y no
      // debugPrint porque debugPrint queda mudo en release y queremos
      // que un audit fallido se vea en la consola del browser.
      try {
        await repo.auditResetPassword(c.id);
      } catch (auditErr) {
        developer.log(
          'audit_reset_password falló para ${c.id}',
          name: 'super_admin',
          error: auditErr,
        );
      }
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('Email de reset enviado a $email'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is AuthException
          ? e.message
          : e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo enviar reset: $msg'),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reenviarInvitacion() async {
    final c = widget.cobrador;
    final email = c.email;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (email == null) {
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: const Text(
            'Este usuario no tiene email registrado. No se puede reenviar.',
          ),
          backgroundColor: scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;

    // Dialog ConsumerStateful que corre el network call internamente
    // (mismo patrón que _CrearTenantDialog). Devuelve null si cancela,
    // o el record completo con nuevaPassword? null/non-null según
    // el modo elegido. Sin esto teníamos un await entre dos modales
    // que en web mostraba un frame en blanco.
    final r = await showDialog<
        ({String newUserId, String email, String? nuevaPassword})>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ReenviarInvitacionDialog(cobrador: c, dialogW: dialogW),
    );
    if (r == null) return;
    container.invalidate(cobradoresTenantProvider(widget.tenantId));
    container.invalidate(tenantsAdminProvider);
    if (!mounted) return;

    final nueva = r.nuevaPassword;
    if (nueva != null && nueva.isNotEmpty) {
      // Path no-email: el server creó al user con password aleatoria;
      // mostramos email + password para copiar. Si el super_admin
      // cierra sin copiar, la password se pierde — puede regenerar con
      // "Forzar contraseña" en la fila del miembro.
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CredencialesDialog(
          title: 'Credenciales de ${c.nombre}',
          email: r.email,
          password: nueva,
          intro: 'Generamos una contraseña nueva para ${c.nombre}. '
              'Pasale email + contraseña por canal seguro — la '
              'invitación anterior dejó de funcionar.',
        ),
      );
    } else {
      // Path email: snackbar tradicional.
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('Invitación reenviada a ${r.email}'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _cambiarRol() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final repo = container.read(superAdminRepoProvider);

    // Re-fetch para que esUltimoAdmin esté basado en datos frescos del
    // server, no en una snapshot de hace minutos.
    container.invalidate(cobradoresTenantProvider(widget.tenantId));
    final miembros = await container
        .read(cobradoresTenantProvider(widget.tenantId).future);
    final otrosAdminsActivos = miembros
        .where((m) => m.rol == 'admin' && m.activo && m.id != c.id)
        .length;
    if (!mounted) return;

    final nuevo = await showDialog<String>(
      context: context,
      builder: (_) => _CambiarRolDialog(
        nombre: c.nombre,
        rolActual: c.rol,
        prefijoActual: c.prefijoRecibo,
        clientesAsignados: c.clientesAsignados,
        esUltimoAdmin: c.rol == 'admin' && otrosAdminsActivos == 0,
      ),
    );
    if (nuevo == null || nuevo == c.rol) return;

    setState(() => _saving = true);
    try {
      await repo.setCobradorRol(
        cobradorId: c.id,
        nuevoRol: nuevo,
      );
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      if (!mounted) return;
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text(
            '${c.nombre}: ${rolLabel(nuevo)}. '
            'Si está logueado, debe salir y volver a entrar.',
          ),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: () async {
              try {
                await repo.setCobradorRol(
                  cobradorId: c.id,
                  nuevoRol: c.rol,
                );
                container.invalidate(
                    cobradoresTenantProvider(widget.tenantId));
                _mostrarSnackBar(
                  messenger,
                  SnackBar(
                    content: Text(
                      '${c.nombre}: revertido a ${rolLabel(c.rol)}',
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
                    backgroundColor:
                        Theme.of(context).colorScheme.error,
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
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo cambiar el rol: $msg'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _forzarPassword() async {
    final c = widget.cobrador;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final repo = container.read(superAdminRepoProvider);

    final nueva = await showDialog<String>(
      context: context,
      // No permitimos dismiss accidental: si el super_admin ya generó una
      // password, debe explícitamente Cancelar o Aplicar.
      barrierDismissible: false,
      builder: (_) => _ForzarPasswordDialog(nombre: c.nombre),
    );
    if (nueva == null || nueva.isEmpty) return;

    setState(() => _saving = true);
    try {
      await repo.forzarPasswordCobrador(
        cobradorId: c.id,
        nuevaPassword: nueva,
      );
      if (!mounted) return;
      // El dialog de copia es CRÍTICO: si el super_admin lo cierra sin
      // copiar pierde la password. Bloqueamos dismiss accidental.
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PasswordCopiarDialog(
          nombre: c.nombre,
          password: nueva,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // Cleaneamos "Exception: " del wrapper del repo para mostrar sólo el
      // mensaje real del servidor.
      final msg = e.toString().replaceFirst('Exception: ', '');
      _mostrarSnackBar(
        messenger,
        SnackBar(
          content: Text('No se pudo cambiar la contraseña: $msg'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
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
      // Warnings que muestra el confirm dialog:
      //   - "último admin": al desactivarlo nadie administra el tenant.
      //   - "clientes huérfanos": si es cobrador con clientes asignados,
      //     quedan sin nadie que los cobre hasta reasignar.
      // Re-fetch antes de leer la lista — así el count y el conteo de
      // admins están frescos (mismo patrón que _cambiarRol).
      container.invalidate(cobradoresTenantProvider(widget.tenantId));
      final miembros = await container
          .read(cobradoresTenantProvider(widget.tenantId).future);
      if (!mounted) return;
      // c también puede estar desactualizado por la invalidación; busco
      // la versión fresca para tomar clientesAsignados correcto.
      final cFresh = miembros.firstWhere(
        (m) => m.id == c.id,
        orElse: () => c,
      );
      final adminsActivos = miembros
          .where((m) => m.rol == 'admin' && m.activo && m.id != cFresh.id)
          .length;
      final esUltimoAdmin = cFresh.rol == 'admin' && adminsActivos == 0;
      final dejaraClientesHuerfanos =
          cFresh.rol == 'cobrador' && cFresh.clientesAsignados > 0;

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
                  const SizedBox(height: 12),
                  _WarningBox(
                    icon: Icons.warning_amber,
                    color: dialogScheme.errorContainer,
                    onColor: dialogScheme.onErrorContainer,
                    texto: 'Es el único admin activo del tenant. Tras '
                        'desactivarlo, nadie podrá administrar este ISP '
                        'hasta que reactives a alguien o invites otro '
                        'admin.',
                  ),
                ],
                if (dejaraClientesHuerfanos) ...[
                  const SizedBox(height: 12),
                  _WarningBox(
                    icon: Icons.warning_amber,
                    color: dialogScheme.errorContainer,
                    onColor: dialogScheme.onErrorContainer,
                    texto:
                        _warningClientesHuerfanos(cFresh.clientesAsignados),
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
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Si hay una acción en curso (spinner), bloqueamos la navegación
        // para que el usuario no pierda el snackbar / feedback en medio.
        onTap: _saving
            ? null
            : () => GoRouter.of(context)
                .go('/super/tenants/${widget.tenantId}/miembros/${c.id}'),
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
                initialsFromName(c.nombre),
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
                      RolChip(rol: c.rol),
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
                      EstadoChip(cobrador: c),
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
                  // Grupo 1: estado.
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
                  const PopupMenuDivider(),
                  // Grupo 2: credenciales.
                  // forzarPassword usa error color porque es la única que
                  // genera una password visible para el super_admin — más
                  // sensible que las otras dos acciones de credenciales.
                  //
                  // Las dos acciones de password están bloqueadas en backend
                  // para super_admin targets (forzar-password edge fn y la
                  // RPC audit_reset_password). Ocultamos del menú para que
                  // el super_admin no envíe un email que después no se va
                  // a poder auditar — además del flow frustrante de tipear
                  // datos y comerse un 403.
                  if (!c.invitacionPendiente && c.rol != 'super_admin')
                    PopupMenuItem(
                      value: _AccionMiembro.forzarPassword,
                      // Label explícito para screen readers — el color
                      // rojo del ícono comunica "sensible" a usuarios
                      // viendo, pero no a quienes navegan con TalkBack.
                      //
                      // Sin button:true — el PopupMenuItem ya provee el
                      // rol "menuitem"; ponerlo de nuevo duplicaría la
                      // anunciación. `hint` se lee con pausa, así no
                      // satura la traversal con texto de workflow.
                      child: Semantics(
                        label: 'Forzar contraseña — acción sensible',
                        hint: 'Genera una contraseña visible para el '
                            'Super Admin',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            Icon(Icons.password,
                                color: scheme.error, size: 20),
                            const SizedBox(width: 12),
                            const Text('Forzar contraseña'),
                          ],
                        ),
                      ),
                    ),
                  if (!c.invitacionPendiente && c.rol != 'super_admin')
                    PopupMenuItem(
                      value: _AccionMiembro.resetPasswordEmail,
                      child: Row(
                        children: [
                          Icon(Icons.mail_outline,
                              color: scheme.tertiary, size: 20),
                          const SizedBox(width: 12),
                          const Text('Reset password vía email'),
                        ],
                      ),
                    ),
                  // Reenviar invitación: sólo para pending invites — el
                  // user no aceptó todavía. Para confirmados usá reset.
                  if (c.invitacionPendiente)
                    PopupMenuItem(
                      value: _AccionMiembro.reenviarInvitacion,
                      child: Row(
                        children: [
                          Icon(Icons.send,
                              color: scheme.tertiary, size: 20),
                          const SizedBox(width: 12),
                          const Text('Reenviar invitación'),
                        ],
                      ),
                    ),
                  const PopupMenuDivider(),
                  // Grupo 3: identidad (rol + email).
                  PopupMenuItem(
                    value: _AccionMiembro.cambiarRol,
                    child: Row(
                      children: [
                        Icon(Icons.swap_horiz,
                            color: scheme.secondary, size: 20),
                        const SizedBox(width: 12),
                        const Text('Cambiar rol'),
                      ],
                    ),
                  ),
                  if (!c.invitacionPendiente)
                    PopupMenuItem(
                      value: _AccionMiembro.cambiarEmail,
                      child: Row(
                        children: [
                          Icon(Icons.alternate_email,
                              color: scheme.secondary, size: 20),
                          const SizedBox(width: 12),
                          const Text('Cambiar email'),
                        ],
                      ),
                    ),
                  // Grupo 4: destructivo (al fondo, separado por divider).
                  // Ocultamos para self y para otros super_admin — el
                  // backend ya bloquea, pero esconder evita el flujo
                  // frustrante de abrir el dialog 'tipear nombre' para
                  // acabar viendo un error.
                  if (c.id !=
                          Supabase
                              .instance.client.auth.currentUser?.id &&
                      c.rol != 'super_admin') ...[
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _AccionMiembro.eliminar,
                      child: Semantics(
                        label: 'Eliminar miembro — acción destructiva',
                        hint: 'Va a pedir confirmación tipeando el '
                            'nombre',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            Icon(Icons.delete_forever,
                                color: scheme.error, size: 20),
                            const SizedBox(width: 12),
                            Text(
                              'Eliminar miembro',
                              style: TextStyle(color: scheme.error),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
      ),
    );
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

/// Dialog de confirmación + ejecución del reenvío de invitación. El
/// switch elige modo (email vs no-email) y se renderea ARRIBA del
/// body para que sea el anchor de la decisión — el resto del contenido
/// (texto explicativo, warning, copy del botón) varía según el modo.
///
/// El dialog corre el network call internamente (mismo patrón que
/// _CrearTenantDialog) — evita el flash entre "confirm pop" y "open
/// credenciales dialog" que se veía cuando dos modales se intercambian
/// con un await en el medio. En éxito devuelve el record completo;
/// el caller decide qué hacer con `nuevaPassword`.
class _ReenviarInvitacionDialog extends ConsumerStatefulWidget {
  const _ReenviarInvitacionDialog({
    required this.cobrador,
    required this.dialogW,
  });

  final CobradorAdmin cobrador;
  final double dialogW;

  @override
  ConsumerState<_ReenviarInvitacionDialog> createState() =>
      _ReenviarInvitacionDialogState();
}

class _ReenviarInvitacionDialogState
    extends ConsumerState<_ReenviarInvitacionDialog> {
  bool _enviarEmail = true;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(superAdminRepoProvider);
      final r = await repo.reenviarInvitacion(
        cobradorId: widget.cobrador.id,
        redirectTo: kIsWeb ? '${Uri.base.origin}/?flow=invite' : null,
        enviarEmail: _enviarEmail,
      );
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final email = widget.cobrador.email ?? '(sin email)';
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text('¿Reenviar invitación a ${widget.cobrador.nombre}?'),
        content: SizedBox(
          width: widget.dialogW,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Switch arriba — es el selector de modo del flow, todo
              // lo de abajo (body, warning, botones) depende de él.
              // Sin esto el user leía la explicación antes de saber
              // qué modo estaba eligiendo.
              SwitchListTile(
                value: _enviarEmail,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _enviarEmail = v),
                title: const Text('Enviar email de invitación'),
                subtitle: Text(
                  _enviarEmail
                      ? 'El usuario recibe el link en su correo.'
                      : 'No se envía email. Te generamos una contraseña '
                          'para compartir manualmente.',
                  style: const TextStyle(fontSize: 11),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(height: 8),
              Text(
                _enviarEmail
                    ? 'Se le enviará un nuevo email de invitación a $email.'
                    : 'Se generará una contraseña nueva para $email '
                        '(no se manda email — la vas a copiar y '
                        'compartir vos).',
              ),
              const SizedBox(height: 12),
              _WarningBox(
                icon: Icons.warning_amber,
                color: s.errorContainer,
                onColor: s.onErrorContainer,
                // Mode-aware: el "qué deja de funcionar" cambia entre
                // invitaciones (link) y contraseñas (string). Antes
                // era "link / contraseña" con slash — ambiguo.
                texto: _enviarEmail
                    ? 'Cualquier invitación anterior deja de '
                        'funcionar. Avisale al usuario que use sólo '
                        'el último email.'
                    : 'Cualquier contraseña anterior deja de '
                        'funcionar. Compartile sólo la nueva.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: s.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            color: s.onErrorContainer, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: s.onErrorContainer,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed:
                _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          // Labels paralelos: ambos describen el artifact resultante
          // ("invitación" en email-mode, "nueva contraseña" en
          // no-email-mode), no el canal. Sin esto teníamos
          // "Reenviar email" (canal) vs "Generar contraseña"
          // (artifact) — verbos descalibrados.
          Semantics(
            button: true,
            enabled: !_busy,
            hint: _enviarEmail
                ? 'Manda un nuevo email de invitación al usuario'
                : 'Genera una contraseña nueva para que la copies',
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_enviarEmail ? Icons.send : Icons.lock_reset),
              label: Text(_busy
                  ? 'Procesando…'
                  : _enviarEmail
                      ? 'Reenviar invitación'
                      : 'Generar nueva contraseña'),
              onPressed: _busy ? null : _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pide / genera una nueva contraseña para un miembro y la devuelve al
/// caller cerrando el dialog con Navigator.pop(password). Si el caller
/// recibe null o "", interpreta cancelación.
class _ForzarPasswordDialog extends StatefulWidget {
  const _ForzarPasswordDialog({required this.nombre});

  final String nombre;

  @override
  State<_ForzarPasswordDialog> createState() => _ForzarPasswordDialogState();
}

class _ForzarPasswordDialogState extends State<_ForzarPasswordDialog> {
  final _ctrl = TextEditingController();
  bool _mostrar = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _generar() {
    // Random.secure() usa una fuente criptográficamente segura del SO.
    // Excluye caracteres ambiguos para dictar (I, l, 1, O, 0) y limita
    // símbolos a los que no se confunden con markdown / espacios.
    const chars =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#%*-+';
    final rand = Random.secure();
    final nueva =
        List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
    setState(() {
      _ctrl.text = nueva;
      _mostrar = true;
      _error = null;
    });
  }

  void _submit() {
    final v = _ctrl.text;
    if (v.length < 8) {
      setState(() => _error = 'Mínimo 8 caracteres');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Responsive width: 420 en desktop/tablet, 90% del viewport en mobile
    // chico (iPhone SE = 375, no entra el 420 fijo).
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return AlertDialog(
      title: Text('¿Forzar nueva contraseña para ${widget.nombre}?'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber,
                      color: scheme.onErrorContainer, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Vas a ver la contraseña una sola vez al terminar. '
                      'El usuario NO recibe notificación — pasásela por '
                      'canal seguro (Whatsapp, en persona).',
                      style: TextStyle(
                          color: scheme.onErrorContainer, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              obscureText: !_mostrar,
              onChanged: (_) {
                // Clear stale error tan pronto el usuario corrige.
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                labelText: 'Nueva contraseña',
                hintText: 'Mínimo 8 caracteres',
                suffixIcon: IconButton(
                  tooltip: _mostrar ? 'Ocultar' : 'Mostrar',
                  icon: Icon(
                      _mostrar ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _mostrar = !_mostrar),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Generar segura'),
                onPressed: _generar,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.lock_reset),
          label: const Text('Aplicar'),
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// Tras forzar la password con éxito, mostramos esto para que el super_admin
/// pueda copiar al portapapeles y comunicar al usuario por canal seguro.
/// Copiar es la acción primaria; cerrar pierde la password permanentemente.
class _PasswordCopiarDialog extends StatefulWidget {
  const _PasswordCopiarDialog({
    required this.nombre,
    required this.password,
  });

  final String nombre;
  final String password;

  @override
  State<_PasswordCopiarDialog> createState() => _PasswordCopiarDialogState();
}

class _PasswordCopiarDialogState extends State<_PasswordCopiarDialog> {
  bool _copiado = false;

  Future<void> _copiar() async {
    await Clipboard.setData(ClipboardData(text: widget.password));
    if (!mounted) return;
    setState(() => _copiado = true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return AlertDialog(
      icon: Icon(Icons.check_circle, color: scheme.primary, size: 40),
      title: Text('Contraseña aplicada para ${widget.nombre}'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Esta es la única oportunidad de copiarla. Al cerrar el '
              'diálogo no vas a poder verla otra vez. Pasásela al usuario '
              'por un canal seguro.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.password,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      // Copiar es la acción PRIMARIA — visualmente más prominente. Listo
      // sólo cierra y la password se pierde.
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_copiado ? 'Listo' : 'Cerrar sin copiar'),
        ),
        FilledButton.icon(
          icon: Icon(_copiado ? Icons.check : Icons.content_copy),
          label: Text(_copiado ? 'Copiada' : 'Copiar contraseña'),
          onPressed: _copiar,
        ),
      ],
    );
  }
}

/// Dialog para elegir un nuevo rol para un miembro del tenant. Devuelve
/// el rol seleccionado vía Navigator.pop(String) o null si se canceló /
/// no cambió la selección.
class _CambiarRolDialog extends StatefulWidget {
  const _CambiarRolDialog({
    required this.nombre,
    required this.rolActual,
    required this.prefijoActual,
    required this.clientesAsignados,
    required this.esUltimoAdmin,
  });

  final String nombre;
  final String rolActual;
  final String? prefijoActual;
  final int clientesAsignados;
  final bool esUltimoAdmin;

  @override
  State<_CambiarRolDialog> createState() => _CambiarRolDialogState();
}

class _CambiarRolDialogState extends State<_CambiarRolDialog> {
  late String _seleccionado;

  @override
  void initState() {
    super.initState();
    _seleccionado = widget.rolActual;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;

    // Warnings que dependen del cambio elegido.
    final perderaAdmin =
        widget.rolActual == 'admin' && _seleccionado != 'admin';
    final dejaraDeSerCobrador =
        widget.rolActual == 'cobrador' && _seleccionado != 'cobrador';
    final dejaraClientesHuerfanos =
        dejaraDeSerCobrador && widget.clientesAsignados > 0;
    final perderaPrefijo =
        dejaraDeSerCobrador && widget.prefijoActual != null;
    final pasaACobradorSinPrefijo = widget.rolActual != 'cobrador' &&
        _seleccionado == 'cobrador';
    final cambioReal = _seleccionado != widget.rolActual;

    return AlertDialog(
      title: Text('¿Cambiar rol de ${widget.nombre}?'),
      content: SizedBox(
        width: dialogW,
        // Wrap en SingleChildScrollView para no clipear contenido en
        // pantallas cortas (laptop landscape, móvil horizontal).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rol actual: ${_label(widget.rolActual)}',
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ..._roles.map((r) {
                final esActual = r == widget.rolActual;
                return RadioListTile<String>(
                  value: r,
                  groupValue: _seleccionado,
                  onChanged: (v) => setState(() => _seleccionado = v!),
                  title: Row(
                    children: [
                      Text(_label(r)),
                      if (esActual) ...[
                        const SizedBox(width: 6),
                        Text(
                          '(actual)',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    _descripcion(r),
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                  tileColor: esActual ? scheme.surfaceContainerLow : null,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                );
              }),
              if (widget.esUltimoAdmin && perderaAdmin) ...[
                const SizedBox(height: 12),
                _WarningBox(
                  icon: Icons.warning_amber,
                  color: scheme.errorContainer,
                  onColor: scheme.onErrorContainer,
                  texto: 'Es el único admin activo del tenant. Tras este '
                      'cambio nadie podrá administrar este ISP hasta que '
                      'designes otro admin.',
                ),
              ],
              if (dejaraClientesHuerfanos) ...[
                const SizedBox(height: 12),
                _WarningBox(
                  icon: Icons.warning_amber,
                  color: scheme.errorContainer,
                  onColor: scheme.onErrorContainer,
                  texto: _warningClientesHuerfanos(widget.clientesAsignados),
                ),
              ],
              if (perderaPrefijo) ...[
                const SizedBox(height: 12),
                _WarningBox(
                  icon: Icons.info_outline,
                  color: scheme.surfaceContainerHighest,
                  onColor: scheme.onSurfaceVariant,
                  texto:
                      'El prefijo de recibo "${widget.prefijoActual}" se '
                      'va a eliminar (no aplica fuera del rol cobrador).',
                ),
              ],
              if (pasaACobradorSinPrefijo) ...[
                const SizedBox(height: 12),
                _WarningBox(
                  icon: Icons.info_outline,
                  color: scheme.surfaceContainerHighest,
                  onColor: scheme.onSurfaceVariant,
                  texto: 'Después tenés que asignarle un prefijo de recibo '
                      'desde el panel del tenant antes de que pueda cobrar.',
                ),
              ],
              if (!cambioReal) ...[
                const SizedBox(height: 12),
                Text(
                  'Elegí un rol distinto al actual para habilitar el cambio.',
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Cambiar'),
          // Color error si hay warning severo (último admin o clientes
          // huérfanos) — alinea visualmente con la severidad del aviso.
          style: ((widget.esUltimoAdmin && perderaAdmin) ||
                  dejaraClientesHuerfanos)
              ? FilledButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.error,
                  foregroundColor:
                      Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: cambioReal
              ? () => Navigator.of(context).pop(_seleccionado)
              : null,
        ),
      ],
    );
  }

  static const _roles = ['admin', 'admin_cobranza', 'cobrador'];

  static String _label(String r) => switch (r) {
        'admin' => 'Administrador',
        'admin_cobranza' => 'Admin de cobranza',
        'cobrador' => 'Cobrador',
        _ => r,
      };

  static String _descripcion(String r) => switch (r) {
        'admin' =>
          'Acceso completo: clientes, contratos, planes, cobradores, config.',
        'admin_cobranza' =>
          'Clientes, contratos, cuotas y pagos. Sin acceso a config.',
        'cobrador' =>
          'Sólo sus clientes asignados. Cobra y emite recibos.',
        _ => '',
      };
}

/// Caja de advertencia con ícono — usada en varios dialogs del panel.
/// 13px para texto en background coloreado: 12px era apenas legible para
/// algunos usuarios; 13px mantiene compactness pero mejora contraste.
class _WarningBox extends StatelessWidget {
  const _WarningBox({
    required this.icon,
    required this.color,
    required this.onColor,
    required this.texto,
  });

  final IconData icon;
  final Color color;
  final Color onColor;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: onColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(color: onColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Texto del warning "tiene N clientes asignados que van a quedar
/// huérfanos". Centralizado para que cambiar-rol y desactivar tengan
/// exactamente la misma copy y para resolver la concordancia
/// gramatical (1 cliente VA, N clientes VAN).
String _warningClientesHuerfanos(int n) {
  if (n == 1) {
    return 'Tiene 1 cliente asignado que va a quedar sin cobrador. '
        'Reasignalo primero desde el panel del tenant '
        '(Cobradores → Reasignar).';
  }
  return 'Tiene $n clientes asignados que van a quedar sin cobrador. '
      'Reasignalos primero desde el panel del tenant '
      '(Cobradores → Reasignar).';
}

/// Pide un nuevo email para un miembro confirmado. Devuelve el email
/// vía Navigator.pop(String) o null si se canceló.
class _CambiarEmailDialog extends StatefulWidget {
  const _CambiarEmailDialog({
    required this.nombre,
    required this.emailActual,
  });

  final String nombre;
  final String emailActual;

  @override
  State<_CambiarEmailDialog> createState() => _CambiarEmailDialogState();
}

class _CambiarEmailDialogState extends State<_CambiarEmailDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) {
      setState(() => _error = 'Ingresá el nuevo email');
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
      setState(() => _error = 'Email inválido');
      return;
    }
    if (v == widget.emailActual) {
      setState(() => _error = 'Ya es ese email');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 420.0;
    return AlertDialog(
      title: Text('Cambiar email de ${widget.nombre}'),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Email actual: ${widget.emailActual}',
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Nuevo email',
                hintText: 'usuario@empresa.com',
              ),
            ),
            const SizedBox(height: 12),
            _WarningBox(
              icon: Icons.info_outline,
              color: scheme.surfaceContainerHighest,
              onColor: scheme.onSurfaceVariant,
              texto: 'El nuevo email queda confirmado automáticamente — no '
                  'se envía verificación. Avisá al usuario por canal '
                  'seguro que su email de login cambió.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.check),
          label: const Text('Cambiar email'),
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// Dialog destructivo para eliminar un miembro. Doble confirmación:
///   1. Aviso explicativo + ack del usuario.
///   2. Tipear el nombre del miembro tal cual para habilitar el botón.
class _EliminarDialog extends StatefulWidget {
  const _EliminarDialog({required this.cobrador});
  final CobradorAdmin cobrador;

  @override
  State<_EliminarDialog> createState() => _EliminarDialogState();
}

class _EliminarDialogState extends State<_EliminarDialog> {
  final _confirmCtrl = TextEditingController();
  bool _entiendo = false;

  @override
  void dispose() {
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _puedeEliminar =>
      _entiendo && _confirmCtrl.text.trim() == widget.cobrador.nombre.trim();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenW = MediaQuery.sizeOf(context).width;
    final dialogW = screenW < 460 ? screenW * 0.9 : 460.0;
    return AlertDialog(
      icon: Icon(Icons.warning_amber, color: scheme.error, size: 36),
      title: Text('¿Eliminar a ${widget.cobrador.nombre}?'),
      content: SizedBox(
        width: dialogW,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WarningBox(
                icon: Icons.warning_amber,
                color: scheme.errorContainer,
                onColor: scheme.onErrorContainer,
                texto: 'Esta acción es PERMANENTE. Si el usuario tiene '
                    'historial operativo (pagos, recibos, clientes '
                    'asignados), la operación va a fallar. Para esos '
                    'casos, usá "Desactivar" — preserva todo el historial.',
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                value: _entiendo,
                onChanged: (v) => setState(() => _entiendo = v ?? false),
                title: const Text(
                  'Entiendo que esta acción no se puede deshacer',
                  style: TextStyle(fontSize: 13),
                ),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 8),
              Text(
                'Tipeá el nombre exacto (con mayúsculas y tildes) '
                'para confirmar:',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              // SelectableText: el usuario puede copiarlo si tiene
              // problemas con tildes/mayúsculas en su teclado.
              // Semantics.label explícito porque sin contexto el SR
              // lee el nombre suelto sin saber su propósito.
              Semantics(
                label: 'Nombre a confirmar: ${widget.cobrador.nombre}',
                excludeSemantics: true,
                child: SelectableText(
                  widget.cobrador.nombre,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  // labelText (no sólo hintText) — NVDA anuncia
                  // "edit, blank" cuando solo hay hint; labelText
                  // queda como nombre accesible del campo.
                  labelText: 'Confirmá tipeando el nombre',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        // Botón destructivo: label rico para screen readers que
        // exponga la naturaleza permanente de la acción. Cuando está
        // disabled el estado se anuncia por Semantics(enabled).
        Semantics(
          button: true,
          enabled: _puedeEliminar,
          label: 'Eliminar permanentemente a ${widget.cobrador.nombre}',
          excludeSemantics: true,
          child: FilledButton.icon(
            icon: const Icon(Icons.delete_forever),
            label: const Text('Eliminar'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              disabledBackgroundColor: scheme.surfaceContainerHighest,
            ),
            onPressed: _puedeEliminar
                ? () => Navigator.of(context).pop(true)
                : null,
          ),
        ),
      ],
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
          // ?flow=invite: para que cuando el invitado clickee el link
          // del email, el app lo route a /set-password en vez del
          // dashboard sin password. Ver _extractAuthFlow en main.dart.
          if (kIsWeb) 'redirect_to': '${Uri.base.origin}/?flow=invite',
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
