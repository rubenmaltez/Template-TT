import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/modulo.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/repositories/super_admin_repo.dart';

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
    final parts = s.trim().split(RegExp(r'\s+'));
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
