import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/error_log_entry.dart';
import '../../data/models/tenant_admin.dart';
import '../../data/repositories/error_logs_repo.dart';
import '../../data/repositories/super_admin_repo.dart';
import '../../data/utils/formatters.dart';
import '../shared/widgets/empty_state.dart';

/// Viewer del backend de error_logs. Solo super_admin lo alcanza
/// (el router guard de `/super` lo cubre y la RPC `list_error_logs`
/// también valida `is_super_admin()`).
class ErrorLogsScreen extends ConsumerWidget {
  const ErrorLogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logsAsync = ref.watch(errorLogsListProvider);
    final tenantsAsync = ref.watch(tenantsAdminProvider);
    final filter = ref.watch(errorLogsFilterProvider);

    return Column(
      children: [
        _FiltrosBar(
          filter: filter,
          tenants: tenantsAsync.valueOrNull ?? const [],
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(errorLogsListProvider),
            child: logsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Error al cargar logs:\n$e'),
                  ),
                ],
              ),
              data: (rows) {
                if (rows.isEmpty) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.bug_report_outlined,
                        titulo: 'Sin errores capturados',
                        descripcion:
                            'Cuando la app capture un crash o '
                            'excepción, aparecerá acá.',
                      ),
                    ],
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _ErrorLogCard(view: rows[i]),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _FiltrosBar extends ConsumerStatefulWidget {
  const _FiltrosBar({required this.filter, required this.tenants});

  final ErrorLogsFilter filter;
  final List<TenantAdmin> tenants;

  @override
  ConsumerState<_FiltrosBar> createState() => _FiltrosBarState();
}

class _FiltrosBarState extends ConsumerState<_FiltrosBar> {
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.filter.search ?? '');
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Buscar en el mensaje…',
                    border: const OutlineInputBorder(),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {});
                              ref
                                  .read(errorLogsFilterProvider.notifier)
                                  .update((f) => f.copyWith(search: null));
                            },
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (v) {
                    ref
                        .read(errorLogsFilterProvider.notifier)
                        .update((f) => f.copyWith(
                              search: v.trim().isEmpty ? null : v.trim(),
                            ));
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  isDense: true,
                  value: filter.tenantId,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Tenant',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Todos'),
                    ),
                    for (final t in widget.tenants)
                      DropdownMenuItem<String?>(
                        value: t.id,
                        child: Text(
                          t.nombre,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    ref
                        .read(errorLogsFilterProvider.notifier)
                        .update((f) => f.copyWith(tenantId: v));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Todos los tipos'),
                  selected: filter.errorType == null,
                  onSelected: (_) {
                    ref
                        .read(errorLogsFilterProvider.notifier)
                        .update((f) => f.copyWith(errorType: null));
                  },
                ),
                const SizedBox(width: 8),
                for (final t in ErrorLogType.values) ...[
                  ChoiceChip(
                    label: Text(_labelForType(t)),
                    selected: filter.errorType == t,
                    onSelected: (_) {
                      ref
                          .read(errorLogsFilterProvider.notifier)
                          .update((f) => f.copyWith(errorType: t));
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorLogCard extends StatelessWidget {
  const _ErrorLogCard({required this.view});
  final ErrorLogView view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _colorForType(view.errorType, scheme);
    final cuando = view.ts.toLocal();

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(_iconForType(view.errorType), color: color, size: 18),
        ),
        title: Text(
          view.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              Text(
                '${Fmt.fechaCorta(cuando)} ${Fmt.hora(cuando)}',
                style: TextStyle(color: scheme.outline, fontSize: 12),
              ),
              if (view.tenantNombre != null)
                _MiniBadge(icon: Icons.business, text: view.tenantNombre!),
              if (view.userNombre != null)
                _MiniBadge(icon: Icons.person, text: view.userNombre!)
              else if (view.userId != null)
                _MiniBadge(icon: Icons.person_off, text: 'Usuario eliminado'),
              _MiniBadge(icon: Icons.label_outline, text: _labelForType(view.errorType)),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _DetailGrid(view: view),
          if (view.stack != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Stack trace',
                  style: TextStyle(color: scheme.outline, fontSize: 12)),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                view.stack!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar todo'),
              onPressed: () => _copiarAlPortapapeles(context, view),
            ),
          ),
        ],
      ),
    );
  }

  void _copiarAlPortapapeles(BuildContext context, ErrorLogView v) {
    final cuando = v.ts.toLocal();
    final buffer = StringBuffer()
      ..writeln('[${Fmt.fechaCorta(cuando)} ${Fmt.hora(cuando)}] '
          '(${v.errorType.name})')
      ..writeln('Tenant: ${v.tenantNombre ?? v.tenantId ?? "—"}')
      ..writeln('User: ${v.userNombre ?? v.userId ?? "—"}')
      ..writeln('Ruta: ${v.route ?? "—"}')
      ..writeln('Versión: ${v.appVersion ?? "—"}')
      ..writeln('Mensaje: ${v.message}')
      ..writeln('Stack:')
      ..writeln(v.stack ?? '(sin stack)');
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log copiado al portapapeles')),
    );
  }
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.view});
  final ErrorLogView view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <(String, String?)>[
      ('Ruta', view.route),
      ('Versión', view.appVersion),
      ('Tenant ID', view.tenantId),
      ('User ID', view.userId),
      ('User agent', view.userAgent),
      ('Reportado', _fmtFull(view.reportedAt.toLocal())),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in items)
          if (value != null && value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(
                      label,
                      style:
                          TextStyle(color: scheme.outline, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  String _fmtFull(DateTime d) =>
      '${Fmt.fechaCorta(d)} ${Fmt.hora(d)}:${d.second.toString().padLeft(2, '0')}';
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: scheme.outline),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(color: scheme.outline, fontSize: 11)),
      ],
    );
  }
}

IconData _iconForType(ErrorLogType t) => switch (t) {
      ErrorLogType.flutter => Icons.flutter_dash,
      ErrorLogType.zone => Icons.bolt,
      ErrorLogType.platform => Icons.memory,
    };

Color _colorForType(ErrorLogType t, ColorScheme s) => switch (t) {
      ErrorLogType.flutter => s.error,
      ErrorLogType.zone => s.tertiary,
      ErrorLogType.platform => s.primary,
    };

/// Label legible para chips/badges (capitaliza el name del enum).
String _labelForType(ErrorLogType t) => switch (t) {
      ErrorLogType.flutter => 'Framework',
      ErrorLogType.zone => 'Async',
      ErrorLogType.platform => 'Plataforma',
    };
