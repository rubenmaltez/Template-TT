// Modelo del LAYOUT configurable del recibo — "diseñador de recibo" (rework).
//
// El recibo se renderiza como una LISTA ORDENADA de bloques; cada bloque tiene
// visibilidad y tamaño de letra. Los 3 renderers (pantalla / PDF / Bluetooth)
// iteran exactamente la misma lista para salir consistentes. Granularidad por
// BLOQUE (Opción A): un dataset (cliente, cuota, etc.) es una unidad.

/// Tamaño de letra de un bloque. Enum de 3 niveles a propósito: la térmica
/// ESC/POS solo soporta ~3 tamaños reales (normal / doble), así que pantalla y
/// PDF mapean estos 3 a px y la térmica al tamaño ESC/POS más cercano.
enum ReciboTextoSize { chico, normal, grande }

ReciboTextoSize reciboSizeFromString(String? s) => switch (s) {
      'chico' => ReciboTextoSize.chico,
      'grande' => ReciboTextoSize.grande,
      _ => ReciboTextoSize.normal,
    };

/// Zona del recibo. Es solo agrupación VISUAL en el editor (header/body/footer);
/// el render por debajo es una sola lista lineal de arriba hacia abajo.
enum ReciboZona { header, body, footer }

ReciboZona? reciboZonaFromString(String? s) => switch (s) {
      'header' => ReciboZona.header,
      'body' => ReciboZona.body,
      'footer' => ReciboZona.footer,
      _ => null,
    };

/// Un bloque del layout: qué bloque es (id), si se muestra, y su tamaño.
class ReciboBloque {
  const ReciboBloque({
    required this.id,
    this.visible = true,
    this.size = ReciboTextoSize.normal,
    this.zona,
  });

  final String id;
  final bool visible;
  final ReciboTextoSize size;

  /// Zona elegida por el usuario (override del default del catálogo). null =
  /// usar la zona del catálogo. Permite mover un bloque entre encabezado/cuerpo/
  /// pie desde el editor (menú "Mover a zona").
  final ReciboZona? zona;

  ReciboBloque copyWith({
    bool? visible,
    ReciboTextoSize? size,
    ReciboZona? zona,
  }) =>
      ReciboBloque(
        id: id,
        visible: visible ?? this.visible,
        size: size ?? this.size,
        zona: zona ?? this.zona,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'visible': visible,
        'size': size.name,
        if (zona != null) 'zona': zona!.name,
      };

  factory ReciboBloque.fromJson(Map<String, dynamic> j) => ReciboBloque(
        id: j['id'] as String,
        visible: j['visible'] as bool? ?? true,
        size: reciboSizeFromString(j['size'] as String?),
        zona: reciboZonaFromString(j['zona'] as String?),
      );
}

/// Metadata de cada bloque disponible: label legible, zona, y si se puede
/// ocultar. El bloque de TOTALES (dinero) NO es ocultable (es la razón de ser
/// del comprobante) — decisión de producto confirmada.
class ReciboBloqueInfo {
  const ReciboBloqueInfo(this.id, this.label, this.zona, {this.hideable = true});
  final String id;
  final String label;
  final ReciboZona zona;
  final bool hideable;
}

/// Catálogo COMPLETO de bloques. El ORDEN de esta lista es el orden por
/// defecto del recibo (coincide con el layout actual de la app).
const kReciboBloquesCatalogo = <ReciboBloqueInfo>[
  ReciboBloqueInfo('logo', 'Logo', ReciboZona.header),
  ReciboBloqueInfo('empresa', 'Datos de la empresa', ReciboZona.header),
  ReciboBloqueInfo('whatsapp', 'WhatsApp', ReciboZona.header),
  ReciboBloqueInfo('titulo', 'Título', ReciboZona.header),
  ReciboBloqueInfo('meta', 'Datos del recibo (N°, fecha, cobrador)', ReciboZona.body),
  ReciboBloqueInfo('cliente', 'Cliente', ReciboZona.body),
  ReciboBloqueInfo('servicio', 'Servicio y período', ReciboZona.body),
  ReciboBloqueInfo('cuota', 'Montos de la cuota', ReciboZona.body),
  ReciboBloqueInfo('metodo', 'Método de pago', ReciboZona.body),
  ReciboBloqueInfo('letras', 'Monto en letras', ReciboZona.body),
  ReciboBloqueInfo('totales', 'Totales (cobrado / vuelto / pagado)', ReciboZona.body,
      hideable: false),
  ReciboBloqueInfo('mora', 'Detalle de mora', ReciboZona.body),
  ReciboBloqueInfo('pie', 'Pie libre', ReciboZona.footer),
];

ReciboBloqueInfo? reciboBloqueInfo(String id) {
  for (final b in kReciboBloquesCatalogo) {
    if (b.id == id) return b;
  }
  return null;
}

/// Zona EFECTIVA de un bloque: la elegida por el usuario (`bloque.zona`) o, si
/// no eligió, la del catálogo.
ReciboZona zonaEfectiva(ReciboBloque b) =>
    b.zona ?? reciboBloqueInfo(b.id)?.zona ?? ReciboZona.body;

/// Helpers de parseo/saneo del layout (robusto a versiones viejas y datos
/// corruptos — nunca se "pierde" un bloque ni se muestra un recibo sin totales).
class ReciboLayout {
  /// Layout por defecto: orden del catálogo, todo visible, tamaño normal.
  static List<ReciboBloque> get porDefecto =>
      kReciboBloquesCatalogo.map((b) => ReciboBloque(id: b.id)).toList();

  /// Parsea el `valor` crudo del setting `recibo.layout` (un array JSON ya
  /// decodificado por `Setting.fromRow`). Reglas defensivas:
  ///  - null / formato inválido → layout por defecto.
  ///  - descarta ids desconocidos (catálogo viejo) y duplicados.
  ///  - agrega AL FINAL los bloques del catálogo que falten (un bloque nuevo en
  ///    una versión futura aparece solo, nunca desaparece).
  ///  - fuerza visible=true en los bloques NO ocultables (totales).
  static List<ReciboBloque> fromRaw(dynamic raw) {
    final out = <ReciboBloque>[];
    final vistos = <String>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final id = item['id'] as String?;
        if (id == null) continue;
        final info = reciboBloqueInfo(id);
        if (info == null || vistos.contains(id)) continue;
        vistos.add(id);
        var b = ReciboBloque.fromJson(Map<String, dynamic>.from(item));
        if (!info.hideable) b = b.copyWith(visible: true);
        out.add(b);
      }
    }
    for (final info in kReciboBloquesCatalogo) {
      if (!vistos.contains(info.id)) out.add(ReciboBloque(id: info.id));
    }
    if (out.isEmpty) return porDefecto;
    // Orden FINAL agrupado por zona EFECTIVA (header → body → footer),
    // preservando el orden dentro de cada zona. Es el orden que iteran los 3
    // renderers y el que muestra/guarda el editor, así un bloque movido de zona
    // (ej. WhatsApp al encabezado) se refleja en el recibo impreso.
    final porZona = <ReciboZona, List<ReciboBloque>>{
      ReciboZona.header: [],
      ReciboZona.body: [],
      ReciboZona.footer: [],
    };
    for (final b in out) {
      porZona[zonaEfectiva(b)]!.add(b);
    }
    return [
      ...porZona[ReciboZona.header]!,
      ...porZona[ReciboZona.body]!,
      ...porZona[ReciboZona.footer]!,
    ];
  }

  static List<Map<String, dynamic>> toJson(List<ReciboBloque> layout) =>
      layout.map((b) => b.toJson()).toList();
}
