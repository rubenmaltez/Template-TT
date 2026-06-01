import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/recibo_layout.dart';
import '../../../data/repositories/settings_repo.dart';

/// Editor del LAYOUT del recibo (rework "diseñador de recibo", fase ③).
///
/// Una lista reordenable de TODOS los bloques del recibo (logo, empresa,
/// cliente, cuota, totales, pie...). Por cada bloque: drag para mover a
/// cualquier parte, toggle de visibilidad (salvo totales, que no se oculta), y
/// selector de tamaño de letra (Chico/Normal/Grande). Cada cambio guarda el
/// setting `recibo.layout` y la vista previa de arriba se actualiza al instante.
class ReciboLayoutEditor extends ConsumerWidget {
  const ReciboLayoutEditor({super.key, required this.tenantId});

  final String tenantId;

  static const _zonaLabel = {
    ReciboZona.header: 'Encabezado',
    ReciboZona.body: 'Cuerpo',
    ReciboZona.footer: 'Pie',
  };
  static const _sizeLabel = {
    ReciboTextoSize.chico: 'Chico',
    ReciboTextoSize.normal: 'Normal',
    ReciboTextoSize.grande: 'Grande',
  };

  void _guardar(WidgetRef ref, List<ReciboBloque> layout) {
    ref
        .read(settingsRepoProvider)
        .update(tenantId, 'recibo.layout', ReciboLayout.toJson(layout));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(appSettingsProvider).reciboLayout;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dashboard_customize, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                const Text('Bloques del recibo',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Arrastrá para ordenar, prendé/apagá cada bloque y elegí su tamaño '
              'de letra. La vista previa de arriba refleja los cambios.',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 8),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              onReorder: (oldIndex, newIndex) {
                final list = [...layout];
                if (newIndex > oldIndex) newIndex -= 1;
                final item = list.removeAt(oldIndex);
                list.insert(newIndex, item);
                _guardar(ref, list);
              },
              children: [
                for (var i = 0; i < layout.length; i++)
                  _BloqueTile(
                    key: ValueKey(layout[i].id),
                    bloque: layout[i],
                    info: reciboBloqueInfo(layout[i].id),
                    zonaLabel: _zonaLabel,
                    sizeLabel: _sizeLabel,
                    onVisible: (v) {
                      final list = [...layout];
                      list[i] = list[i].copyWith(visible: v);
                      _guardar(ref, list);
                    },
                    onSize: (s) {
                      final list = [...layout];
                      list[i] = list[i].copyWith(size: s);
                      _guardar(ref, list);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BloqueTile extends StatelessWidget {
  const _BloqueTile({
    required super.key,
    required this.bloque,
    required this.info,
    required this.zonaLabel,
    required this.sizeLabel,
    required this.onVisible,
    required this.onSize,
  });

  final ReciboBloque bloque;
  final ReciboBloqueInfo? info;
  final Map<ReciboZona, String> zonaLabel;
  final Map<ReciboTextoSize, String> sizeLabel;
  final ValueChanged<bool> onVisible;
  final ValueChanged<ReciboTextoSize> onSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hideable = info?.hideable ?? true;
    final atenuado = !bloque.visible;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.drag_handle, size: 20, color: scheme.outline),
          const SizedBox(width: 8),
          // Label + zona.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info?.label ?? bloque.id,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: atenuado ? scheme.outline : null,
                  ),
                ),
                Text(
                  zonaLabel[info?.zona] ?? '',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
          // Selector de tamaño (solo si el bloque está visible).
          if (bloque.visible)
            DropdownButton<ReciboTextoSize>(
              value: bloque.size,
              isDense: true,
              underline: const SizedBox.shrink(),
              onChanged: (s) {
                if (s != null) onSize(s);
              },
              items: [
                for (final s in ReciboTextoSize.values)
                  DropdownMenuItem(value: s, child: Text(sizeLabel[s]!)),
              ],
            ),
          const SizedBox(width: 4),
          // Visibilidad. Totales no se puede ocultar (switch deshabilitado en ON).
          Switch.adaptive(
            value: bloque.visible,
            onChanged: hideable ? onVisible : null,
          ),
        ],
      ),
    );
  }
}
