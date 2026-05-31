import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/settings_repo.dart';

/// Editor de ORDEN de los bloques de texto del pie del recibo (#8b): el admin
/// arrastra para reordenar "Pie libre" y "WhatsApp". Guarda el CSV en el
/// setting `recibo.orden_pie`. La vista previa de arriba refleja el cambio al
/// instante (ambos leen `appSettingsProvider`).
class ReciboPieOrderEditor extends ConsumerWidget {
  const ReciboPieOrderEditor({super.key, required this.tenantId});

  final String tenantId;

  static const _labels = {'pie': 'Pie libre', 'whatsapp': 'WhatsApp'};
  static const _iconos = {'pie': Icons.notes, 'whatsapp': Icons.chat_bubble_outline};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orden = ref.watch(appSettingsProvider).reciboOrdenPie;
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
                Icon(Icons.reorder, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                const Text('Orden del pie del recibo',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Arrastrá para ordenar el pie libre y el WhatsApp. Cada bloque '
              'aparece solo si tiene contenido.',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 8),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              onReorder: (oldIndex, newIndex) {
                final list = [...orden];
                // Ajuste estándar de índice de ReorderableListView.
                if (newIndex > oldIndex) newIndex -= 1;
                final item = list.removeAt(oldIndex);
                list.insert(newIndex, item);
                ref
                    .read(settingsRepoProvider)
                    .update(tenantId, 'recibo.orden_pie', list.join(','));
              },
              children: [
                for (final id in orden)
                  ListTile(
                    key: ValueKey(id),
                    dense: true,
                    leading: Icon(_iconos[id] ?? Icons.notes, size: 20),
                    title: Text(_labels[id] ?? id),
                    trailing: const Icon(Icons.drag_handle),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
