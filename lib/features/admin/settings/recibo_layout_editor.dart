import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/recibo_layout.dart';
import '../../../data/repositories/settings_repo.dart';
import 'recibo_preview.dart';

/// Diseñador del recibo (rework). Dos columnas:
///  - IZQUIERDA: ajustes generales (ancho, título, pie) + los bloques del
///    recibo SEGMENTADOS por Encabezado / Cuerpo / Pie. Cada bloque se arrastra
///    para reordenar (dentro de su segmento), se prende/apaga y se le elige el
///    tamaño de letra. Sub-opciones (cédula, saldo) viven dentro de su bloque.
///  - DERECHA: vista previa en vivo, siempre visible mientras editás.
///
/// Ocupa toda la tab Recibos (la pantalla de settings le da altura completa, no
/// va dentro del ListView de tiles genéricos).
class ReciboLayoutEditor extends ConsumerWidget {
  const ReciboLayoutEditor({super.key, required this.tenantId});

  final String tenantId;

  static const _zonas = [
    (ReciboZona.header, 'Encabezado', Icons.vertical_align_top),
    (ReciboZona.body, 'Cuerpo', Icons.notes),
    (ReciboZona.footer, 'Pie', Icons.vertical_align_bottom),
  ];

  void _save(WidgetRef ref, List<ReciboBloque> layout) {
    // upsert (no update): los tenants creados DESPUÉS de la migración 0080 no
    // tienen la fila `recibo.layout` sembrada (el trigger de alta llama
    // seed_settings_default, que no la incluye). Con un UPDATE puro el toggle
    // no afectaba ninguna fila y "rebotaba". upsert la inserta si falta.
    ref.read(settingsRepoProvider).upsert(
          tenantId,
          'recibo.layout',
          ReciboLayout.toJson(layout),
          tipo: 'json',
          categoria: 'recibos',
        );
  }

  Future<void> _resetLayout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restaurar layout'),
        content: const Text(
            'Vuelve el recibo al orden y las zonas por defecto (incluye WhatsApp '
            'en el encabezado). ¿Continuar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok == true) _save(ref, ReciboLayout.porDefecto);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final layout = settings.reciboLayout;

    // Agrupar por zona del catálogo, preservando el orden flat de cada zona.
    final grupos = <ReciboZona, List<ReciboBloque>>{
      ReciboZona.header: [],
      ReciboZona.body: [],
      ReciboZona.footer: [],
    };
    for (final b in layout) {
      grupos[zonaEfectiva(b)]!.add(b);
    }

    // Reconstruye el layout flat SIEMPRE zona-agrupado (header → body → footer),
    // que es justo el orden que iteran los renderers. Así lo que ves en los
    // segmentos coincide exacto con cómo se imprime.
    List<ReciboBloque> rebuild() => [
          ...grupos[ReciboZona.header]!,
          ...grupos[ReciboZona.body]!,
          ...grupos[ReciboZona.footer]!,
        ];

    void reordenar(ReciboZona zona, int oldIndex, int newIndex) {
      final list = grupos[zona]!;
      if (newIndex > oldIndex) newIndex -= 1;
      list.insert(newIndex, list.removeAt(oldIndex));
      _save(ref, rebuild());
    }

    void actualizar(ReciboZona zona, int i, ReciboBloque nuevo) {
      grupos[zona]![i] = nuevo;
      _save(ref, rebuild());
    }

    // Mueve un bloque de una zona a otra (lo agrega al final de la destino con
    // su override `zona` seteado). El orden por zona lo reconstruye `rebuild()`.
    void moverAZona(ReciboZona origen, int i, ReciboZona destino) {
      if (origen == destino) return;
      final b = grupos[origen]!.removeAt(i);
      grupos[destino]!.add(b.copyWith(zona: destino));
      _save(ref, rebuild());
    }

    final editorChildren = <Widget>[
      _AjustesGenerales(tenantId: tenantId),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('Restaurar layout por defecto'),
          onPressed: () => _resetLayout(context, ref),
        ),
      ),
      const SizedBox(height: 8),
      for (final (zona, label, icon) in _zonas)
        _Segmento(
          label: label,
          icon: icon,
          zona: zona,
          bloques: grupos[zona]!,
          onReorder: (o, n) => reordenar(zona, o, n),
          onVisible: (i, v) =>
              actualizar(zona, i, grupos[zona]![i].copyWith(visible: v)),
          onSize: (i, s) =>
              actualizar(zona, i, grupos[zona]![i].copyWith(size: s)),
          onMover: (i, destino) => moverAZona(zona, i, destino),
          tenantId: tenantId,
        ),
    ];

    // Preview a la derecha (siempre visible) en pantalla ancha; apilado arriba
    // en angosta. Los hijos del editor van DIRECTO en un único ListView (no
    // anidado) para no romper el scroll por altura sin límite.
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 900) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const ReciboPreview(),
              const SizedBox(height: 20),
              ...editorChildren,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: editorChildren,
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 360,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: const [ReciboPreview()],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Ajustes generales (ancho de papel, título, pie). StatefulWidget por los
// controllers de texto (no se pisan en rebuilds).
// ───────────────────────────────────────────────────────────────────────
class _AjustesGenerales extends ConsumerStatefulWidget {
  const _AjustesGenerales({required this.tenantId});
  final String tenantId;
  @override
  ConsumerState<_AjustesGenerales> createState() => _AjustesGeneralesState();
}

class _AjustesGeneralesState extends ConsumerState<_AjustesGenerales> {
  late final TextEditingController _titulo;
  late final TextEditingController _pie;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appSettingsProvider);
    _titulo = TextEditingController(text: s.reciboTitulo);
    _pie = TextEditingController(text: s.pieRecibo);
  }

  @override
  void dispose() {
    _titulo.dispose();
    _pie.dispose();
    super.dispose();
  }

  // upsert (no update): mismas claves de recibo pueden no estar sembradas en
  // tenants nuevos (ver nota en ReciboLayoutEditor._save). upsert la crea si
  // falta. `tipo` por clave para que la fila nueva quede bien tipada.
  void _save(String clave, dynamic valor, {String tipo = 'string'}) {
    ref.read(settingsRepoProvider).upsert(
          widget.tenantId,
          clave,
          valor,
          tipo: tipo,
          categoria: 'recibos',
        );
  }

  @override
  Widget build(BuildContext context) {
    final ancho = ref.watch(appSettingsProvider).formatoReciboMm;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TituloSeccion('Ajustes generales', Icons.tune),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 90, child: Text('Ancho de papel')),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: ancho == 80 ? 80 : 58,
                  onChanged: (v) {
                    if (v != null) {
                      _save('recibo.formato_default_mm', v, tipo: 'number');
                    }
                  },
                  items: const [
                    DropdownMenuItem(value: 80, child: Text('80 mm (estándar)')),
                    DropdownMenuItem(value: 58, child: Text('58 mm')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titulo,
              decoration: const InputDecoration(
                labelText: 'Título del recibo',
                hintText: 'RECIBO, COBRO…',
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
              onSubmitted: (v) => _save('recibo.titulo', v.trim()),
              onTapOutside: (_) => _save('recibo.titulo', _titulo.text.trim()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pie,
              decoration: const InputDecoration(
                labelText: 'Pie del recibo',
                hintText: '¡Gracias por su pago!',
                isDense: true,
              ),
              minLines: 1,
              maxLines: 3,
              onSubmitted: (v) => _save('recibo.pie_libre', v.trim()),
              onTapOutside: (_) => _save('recibo.pie_libre', _pie.text.trim()),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Un segmento (Encabezado / Cuerpo / Pie) con sus bloques reordenables.
// ───────────────────────────────────────────────────────────────────────
class _Segmento extends StatelessWidget {
  const _Segmento({
    required this.label,
    required this.icon,
    required this.zona,
    required this.bloques,
    required this.onReorder,
    required this.onVisible,
    required this.onSize,
    required this.onMover,
    required this.tenantId,
  });

  final String label;
  final IconData icon;
  final ReciboZona zona;
  final List<ReciboBloque> bloques;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index, bool visible) onVisible;
  final void Function(int index, ReciboTextoSize size) onSize;
  final void Function(int index, ReciboZona destino) onMover;
  final String tenantId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TituloSeccion(label, icon),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: bloques.length,
              onReorder: onReorder,
              itemBuilder: (ctx, i) => _BloqueRow(
                key: ValueKey(bloques[i].id),
                index: i,
                bloque: bloques[i],
                info: reciboBloqueInfo(bloques[i].id),
                tenantId: tenantId,
                zonaActual: zona,
                onVisible: (v) => onVisible(i, v),
                onSize: (s) => onSize(i, s),
                onMover: (destino) => onMover(i, destino),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TituloSeccion extends StatelessWidget {
  const _TituloSeccion(this.label, this.icon);
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 0.8,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Fila de un bloque: drag + nombre + tamaño + visibilidad (+ sub-toggle).
// ───────────────────────────────────────────────────────────────────────
class _BloqueRow extends ConsumerWidget {
  const _BloqueRow({
    required super.key,
    required this.index,
    required this.bloque,
    required this.info,
    required this.tenantId,
    required this.zonaActual,
    required this.onVisible,
    required this.onSize,
    required this.onMover,
  });

  final int index;
  final ReciboBloque bloque;
  final ReciboBloqueInfo? info;
  final String tenantId;
  final ReciboZona zonaActual;
  final ValueChanged<bool> onVisible;
  final ValueChanged<ReciboTextoSize> onSize;
  final ValueChanged<ReciboZona> onMover;

  // Sub-opción de un bloque (cédula del cliente, saldo de la cuota): clave del
  // setting booleano que vive DENTRO del bloque.
  String? get _subClave => switch (bloque.id) {
        'cliente' => 'recibo.mostrar_cedula',
        'cuota' => 'recibo.mostrar_adeudado',
        _ => null,
      };
  String get _subLabel =>
      bloque.id == 'cliente' ? 'Mostrar cédula' : 'Mostrar saldo pendiente';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hideable = info?.hideable ?? true;
    final off = !bloque.visible;
    final subClave = _subClave;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.drag_indicator,
                      size: 22, color: scheme.outline),
                ),
              ),
              Expanded(
                child: Text(
                  info?.label ?? bloque.id,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: off ? scheme.outline : null,
                  ),
                ),
              ),
              // Tamaño (solo si el bloque está visible).
              if (!off) ...[
                _SelectorTamano(size: bloque.size, onSize: onSize),
                const SizedBox(width: 12),
              ],
              // Visibilidad. El bloque de totales no se puede ocultar.
              if (hideable)
                Switch(value: bloque.visible, onChanged: onVisible)
              else
                Tooltip(
                  message: 'El total no se puede ocultar',
                  child: Icon(Icons.lock, size: 20, color: scheme.outline),
                ),
              // Menú "Mover a zona": reubica el bloque entre encabezado / cuerpo
              // / pie (además del drag para reordenar dentro de la zona).
              PopupMenuButton<ReciboZona>(
                icon: Icon(Icons.more_vert, size: 20, color: scheme.outline),
                tooltip: 'Mover a zona',
                onSelected: onMover,
                itemBuilder: (_) => [
                  for (final (z, etiqueta) in const [
                    (ReciboZona.header, 'Mover a Encabezado'),
                    (ReciboZona.body, 'Mover a Cuerpo'),
                    (ReciboZona.footer, 'Mover a Pie'),
                  ])
                    if (z != zonaActual)
                      PopupMenuItem(value: z, child: Text(etiqueta)),
                ],
              ),
            ],
          ),
        ),
        // Sub-toggle dentro del bloque (cédula / saldo), indentado.
        if (subClave != null && !off)
          Padding(
            padding: const EdgeInsets.only(left: 42, bottom: 4),
            child: Row(
              children: [
                Icon(Icons.subdirectory_arrow_right,
                    size: 16, color: scheme.outline),
                const SizedBox(width: 4),
                Text(_subLabel,
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                const Spacer(),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: _subValor(ref, subClave),
                    // upsert: el sub-toggle (cédula/saldo) también puede no
                    // tener su fila en tenants nuevos. Lo crea si falta.
                    onChanged: (v) => ref.read(settingsRepoProvider).upsert(
                          tenantId,
                          subClave,
                          v,
                          tipo: 'boolean',
                          categoria: 'recibos',
                        ),
                  ),
                ),
              ],
            ),
          ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ],
    );
  }

  bool _subValor(WidgetRef ref, String clave) {
    final s = ref.watch(appSettingsProvider);
    return clave == 'recibo.mostrar_cedula'
        ? s.reciboMostrarCedula
        : s.reciboMostrarAdeudado;
  }
}

/// Selector de tamaño de letra compacto: tres "A" de distinto tamaño.
class _SelectorTamano extends StatelessWidget {
  const _SelectorTamano({required this.size, required this.onSize});
  final ReciboTextoSize size;
  final ValueChanged<ReciboTextoSize> onSize;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ReciboTextoSize>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment(
          value: ReciboTextoSize.chico,
          label: Text('A', style: TextStyle(fontSize: 11)),
          tooltip: 'Chico',
        ),
        ButtonSegment(
          value: ReciboTextoSize.normal,
          label: Text('A', style: TextStyle(fontSize: 14)),
          tooltip: 'Normal',
        ),
        ButtonSegment(
          value: ReciboTextoSize.grande,
          label: Text('A', style: TextStyle(fontSize: 17)),
          tooltip: 'Grande',
        ),
      ],
      selected: {size},
      onSelectionChanged: (s) => onSize(s.first),
    );
  }
}
