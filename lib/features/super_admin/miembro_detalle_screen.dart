import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/audit_entry.dart';
import '../../data/models/cobrador_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/skeleton.dart';

/// Pantalla de detalle de un miembro del tenant. Muestra:
///   - Header con info básica (avatar, nombre, email, chips de rol/estado)
///   - Stats: última sesión, clientes asignados, cobrado del mes
///   - Auditoría: últimos eventos sobre este usuario
///
/// Las acciones (cambiar rol, forzar password, etc.) siguen viviendo en
/// el popup `⋮` de la lista de miembros — esta pantalla es read-only.
/// Más adelante agregamos también acciones cambiar email / borrar acá.
class MiembroDetalleScreen extends ConsumerWidget {
  const MiembroDetalleScreen({
    super.key,
    required this.tenantId,
    required this.cobradorId,
  });

  final String tenantId;
  final String cobradorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Buscamos al miembro en la lista cacheada del tenant — ya está
    // poblada al venir desde la pantalla padre, no requiere RPC extra.
    final miembros = ref.watch(cobradoresTenantProvider(tenantId));
    final statsAsync = ref.watch(cobradorStatsProvider(cobradorId));
    final auditAsync = ref.watch(auditCobradorProvider(cobradorId));

    return miembros.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (lista) {
        final c = lista.where((m) => m.id == cobradorId).firstOrNull;
        if (c == null) {
          return const EmptyState(
            icon: Icons.person_off,
            titulo: 'Miembro no encontrado',
            descripcion: 'Puede haber sido eliminado o cambiado de tenant.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(cobradorStatsProvider(cobradorId));
            ref.invalidate(auditCobradorProvider(cobradorId));
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Header(cobrador: c),
              const SizedBox(height: 24),
              Text('Stats',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              _StatsGrid(stats: statsAsync, cobrador: c),
              const SizedBox(height: 24),
              Text('Auditoría reciente',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Últimos cambios registrados sobre este miembro.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              _AuditTimeline(audit: auditAsync),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.cobrador});
  final CobradorAdmin cobrador;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rolColor = _rolColor(scheme, cobrador.rol);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: cobrador.activo
                  ? rolColor.withValues(alpha: 0.15)
                  : scheme.surfaceContainerHighest,
              foregroundColor:
                  cobrador.activo ? rolColor : scheme.outline,
              child: Text(
                _initials(cobrador.nombre),
                style: const TextStyle(
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
                  Text(
                    cobrador.nombre,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cobrador.email ?? '(sin email)',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  if (cobrador.telefono != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      cobrador.telefono!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _Chip(
                        label: _rolLabel(cobrador.rol),
                        bg: rolColor.withValues(alpha: 0.15),
                        fg: rolColor,
                      ),
                      _Chip(
                        label: cobrador.activo
                            ? 'Activo'
                            : cobrador.invitacionPendiente
                                ? 'Invitación pendiente'
                                : 'Inactivo',
                        bg: cobrador.activo
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        fg: cobrador.activo
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                      if (cobrador.prefijoRecibo != null)
                        _Chip(
                          label: 'Prefijo ${cobrador.prefijoRecibo}',
                          bg: scheme.surfaceContainerHighest,
                          fg: scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
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

  static String _rolLabel(String rol) => switch (rol) {
        'super_admin' => 'Super Admin',
        'admin' => 'Administrador',
        'admin_cobranza' => 'Admin de cobranza',
        'cobrador' => 'Cobrador',
        _ => rol,
      };

  static String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.bg, required this.fg});
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats, required this.cobrador});

  final AsyncValue<dynamic> stats;
  final CobradorAdmin cobrador;

  @override
  Widget build(BuildContext context) {
    return stats.when(
      loading: () => const _StatsSkeleton(),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No se pudieron cargar las stats: $e'),
        ),
      ),
      data: (s) {
        // s puede ser null si el cobrador es super_admin (excluido por
        // la RPC). En ese caso caemos a defaults para que la UI no rompa.
        final lastSignIn = s?.lastSignInAt as DateTime?;
        final clientes = (s?.clientesAsignados as int?) ?? 0;
        final pagosCount = (s?.pagosMesCount as int?) ?? 0;
        final pagosTotal = (s?.pagosMesTotal as double?) ?? 0.0;
        return LayoutBuilder(
          builder: (_, constraints) {
            final wide = constraints.maxWidth > 600;
            final children = [
              _StatCard(
                icon: Icons.schedule,
                label: 'Última sesión',
                valor: _ultimoLogin(lastSignIn),
                hint: lastSignIn != null
                    ? Fmt.fechaLarga(lastSignIn)
                    : 'Nunca inició sesión',
              ),
              _StatCard(
                icon: Icons.people_outline,
                label: 'Clientes asignados',
                valor: clientes.toString(),
                hint: cobrador.rol == 'cobrador'
                    ? 'Activos en su ruta'
                    : 'Solo aplica a rol cobrador',
              ),
              _StatCard(
                icon: Icons.payments_outlined,
                label: 'Cobrado este mes',
                valor: 'C\$ ${pagosTotal.toStringAsFixed(2)}',
                hint: '$pagosCount cobros',
              ),
            ];
            return wide
                ? Row(
                    children: children
                        .expand((c) => [
                              Expanded(child: c),
                              const SizedBox(width: 12),
                            ])
                        .toList()
                      ..removeLast(),
                  )
                : Column(
                    children: children
                        .expand((c) => [c, const SizedBox(height: 12)])
                        .toList()
                      ..removeLast(),
                  );
          },
        );
      },
    );
  }

  static String _ultimoLogin(DateTime? t) {
    if (t == null) return 'Nunca';
    final raw = DateTime.now().difference(t).inDays;
    final dias = raw < 0 ? 0 : raw;
    if (dias == 0) return 'Hoy';
    if (dias == 1) return 'Ayer';
    if (dias < 30) return 'Hace $dias días';
    return Fmt.fechaLarga(t);
  }
}

class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final wide = constraints.maxWidth > 600;
        Widget item() => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    SkeletonBox(width: 100, height: 12),
                    SizedBox(height: 12),
                    SkeletonBox(width: 80, height: 24),
                    SizedBox(height: 6),
                    SkeletonBox(width: 60, height: 11),
                  ],
                ),
              ),
            );
        return wide
            ? Row(
                children: [
                  Expanded(child: item()),
                  const SizedBox(width: 12),
                  Expanded(child: item()),
                  const SizedBox(width: 12),
                  Expanded(child: item()),
                ],
              )
            : Column(
                children: [
                  item(),
                  const SizedBox(height: 12),
                  item(),
                  const SizedBox(height: 12),
                  item(),
                ],
              );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.valor,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String valor;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              valor,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                hint!,
                style: TextStyle(
                  color: scheme.outline,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AuditTimeline extends StatelessWidget {
  const _AuditTimeline({required this.audit});

  final AsyncValue<List<AuditEntry>> audit;

  @override
  Widget build(BuildContext context) {
    return audit.when(
      loading: () => const SkeletonList(
        count: 3,
        hasAvatar: false,
        hasChip: false,
      ),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No se pudo cargar la auditoría: $e'),
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'Sin cambios registrados en la auditoría.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          );
        }
        return Column(
          children: entries.map((e) => _AuditTile(entry: e)).toList(),
        );
      },
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry});
  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _resumenCambio(entry),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Por ${entry.autorDisplay}'
                    '${entry.userRol != null ? " (${entry.userRol})" : ""}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fechaRelativa(entry.createdAt),
                    style: TextStyle(
                      color: scheme.outline,
                      fontSize: 11,
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

  /// Resumen humano del cambio según los campos del audit_log.
  /// `campo` indica qué se cambió; valor_anterior/nuevo son jsonb.
  String _resumenCambio(AuditEntry e) {
    final campo = e.campo ?? '(evento)';
    final anterior = _formatVal(e.valorAnterior);
    final nuevo = _formatVal(e.valorNuevo);
    if (e.valorAnterior == null && e.valorNuevo != null) {
      // Eventos tipo 'force_password_reset' que sólo registran acción.
      final action = e.valorNuevo is Map
          ? (e.valorNuevo as Map)['action']?.toString()
          : null;
      if (action != null) return _accionLabel(action);
      return '$campo: $nuevo';
    }
    return '$campo: $anterior → $nuevo';
  }

  static String _formatVal(dynamic v) {
    if (v == null) return '—';
    if (v is bool) return v ? 'sí' : 'no';
    if (v is Map) {
      // Para audit rows con action embebida.
      final action = v['action']?.toString();
      if (action != null) return action;
      return v.toString();
    }
    return v.toString();
  }

  static String _accionLabel(String action) => switch (action) {
        'force_password_reset' => 'Contraseña reseteada por super_admin',
        'resent_invitation' => 'Invitación reenviada',
        'previous_invite' => 'Invitación previa',
        _ => action,
      };

  String _fechaRelativa(DateTime t) {
    final raw = DateTime.now().difference(t);
    if (raw.isNegative) return 'ahora';
    if (raw.inSeconds < 60) return 'hace unos segundos';
    if (raw.inMinutes < 60) return 'hace ${raw.inMinutes} min';
    if (raw.inHours < 24) return 'hace ${raw.inHours} h';
    if (raw.inDays == 1) return 'ayer';
    if (raw.inDays < 30) return 'hace ${raw.inDays} días';
    return Fmt.fechaLarga(t);
  }
}
