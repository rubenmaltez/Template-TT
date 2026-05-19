import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/animated_list_entry.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/skeleton.dart';

/// Lista de tenants — pantalla raíz del panel /super.
class TenantsListScreen extends ConsumerWidget {
  const TenantsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenantsAsync = ref.watch(tenantsAdminProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(tenantsAdminProvider),
      child: tenantsAsync.when(
        // Skeleton imitando la altura final — sin layout jump al cargar.
        // Usamos ListView (no SingleChildScrollView) para que el
        // RefreshIndicator funcione consistente entre loading y data.
        loading: () => ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            SkeletonList(
              count: 3,
              hasAvatar: true,
              hasChip: true,
              cardMarginBottom: 12,
            ),
          ],
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Error cargando tenants:\n$e',
                textAlign: TextAlign.center),
          ),
        ),
        data: (tenants) {
          if (tenants.isEmpty) {
            return const EmptyState(
              icon: Icons.business,
              titulo: 'Sin tenants',
              descripcion:
                  'Aún no creaste ningún ISP. Andá a Supabase Dashboard '
                  '→ Authentication → Users → "Add user" para invitar al '
                  'primer admin de un tenant nuevo.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: tenants.length,
            itemBuilder: (_, i) => AnimatedListEntry(
              // Key estable por id: si la lista crece/shrinkea, los items
              // existentes no se re-animan ni se descolocan.
              key: ValueKey(tenants[i].id),
              index: i,
              child: _TenantCard(tenant: tenants[i]),
            ),
          );
        },
      ),
    );
  }
}

class _TenantCard extends StatefulWidget {
  const _TenantCard({required this.tenant});
  final TenantAdmin tenant;

  @override
  State<_TenantCard> createState() => _TenantCardState();
}

class _TenantCardState extends State<_TenantCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tenant = widget.tenant;
    // Reduce motion (WCAG): si el OS lo pide, animamos sin duración.
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final animDur = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 150);
    // Lift sólo si hover activo Y no reducimos motion.
    final lift = (_hover && !reduceMotion) ? -2.0 : 0.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // AnimatedContainer maneja color, shadow y desplazamiento en una sola
      // animación. Material transparente adentro para que el InkWell tenga
      // su ripple sin pelearse con el bg.
      child: AnimatedContainer(
        duration: animDur,
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 12),
        transform: Matrix4.identity()..translate(0.0, lift),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          // Salto de 2 tonos en dark theme + borde sutil en hover para
          // que la diferencia sea perceptible (sin border, surfaceLow→High
          // en dark es apenas visible).
          color: _hover
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hover ? scheme.outlineVariant : Colors.transparent,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: _hover ? 0.18 : 0.05),
              blurRadius: _hover ? 10 : 3,
              offset: Offset(0, _hover ? 4 : 1),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.go('/super/tenants/${tenant.id}'),
            child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      _initials(tenant.nombre),
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tenant.nombre,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Creado ${Fmt.fechaLarga(tenant.createdAt)}',
                          style: TextStyle(
                              color: scheme.outline, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.people_outline,
                      size: 16, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    '${tenant.cobradoresCount} cobradores activos',
                    style: TextStyle(color: scheme.outline, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tenant.modulosHabilitados
                    .map((m) => Chip(
                          label: Text(m),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: scheme.secondaryContainer,
                          labelStyle:
                              TextStyle(color: scheme.onSecondaryContainer),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
          ),
        ),
      ),
    );
  }

  String _initials(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}
