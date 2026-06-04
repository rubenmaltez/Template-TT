import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/setting.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/logo_empresa_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../shared/widgets/empty_state.dart';
import 'recibo_layout_editor.dart';
import 'settings_groups.dart';

/// Panel de configuración. Agrupa settings por categoría en pestañas; dentro
/// de cada pestaña, en tarjetas-sección (`SettingGroup`). Algunas secciones
/// tienen un toggle padre que REVELA campos hijos (reveal animado).
///
/// Sólo admin puede editar la mayoría; admin_cobranza puede tocar las settings
/// marcadas con editable_por='admin_cobranza' (ej. tasa USD). La tab "Avanzado"
/// sólo la ve el super_admin (settings que consumen recursos del SaaS +
/// pantallas opcionales del tenant + link a "Campos del historial").
class SettingsAdminScreen extends ConsumerWidget {
  const SettingsAdminScreen({super.key});

  // Tabs base (todos los roles con acceso admin). "Avanzado" se agrega aparte
  // sólo para super_admin (ver build).
  static const _categoriasBase = [
    ('empresa', 'Empresa', Icons.business),
    ('cobranza', 'Cobranza', Icons.receipt_long),
    ('pagos', 'Pagos', Icons.payments),
    // Tab "Moneda" removido: la moneda principal SIEMPRE es córdoba (NIO). El
    // dólar es método de pago ALTERNO (con tasa de cambio, vuelto en córdobas),
    // no una moneda principal — el setting confundía. moneda.principal queda
    // huérfano en la DB (nadie lo lee; la app ya asume NIO).
    // Tab "Cuotas" removido a pedido (cuotas manuales / editar monto fuera de
    // scope por ahora). El feature sigue en el código; solo se oculta de
    // settings. Los settings cuotas.* quedan huérfanos en la DB (sin tab).
    ('recibos', 'Recibos', Icons.print),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsMapProvider);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    // super_admin hereda permisos de admin.
    final esAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;

    // La tab "Avanzado" (settings super_admin-only + link historial) sólo se
    // agrega para el super_admin. Orden: Empresa · Cobranza · Pagos · Recibos
    // · [Avanzado].
    final categorias = [
      ..._categoriasBase,
      if (esSuperAdmin) ('avanzado', 'Avanzado', Icons.tune),
    ];

    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (settings) {
        if (settings.isEmpty) {
          return const EmptyState(
            icon: Icons.settings,
            titulo: 'Sin configuración',
            descripcion: 'Esperando primera sincronización.',
          );
        }
        return DefaultTabController(
          length: categorias.length,
          child: Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: TabBar(
                  isScrollable: true,
                  indicatorColor: Theme.of(context).colorScheme.primary,
                  labelColor: Theme.of(context).colorScheme.primary,
                  unselectedLabelColor: Theme.of(context).colorScheme.outline,
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerColor: Theme.of(context).colorScheme.outlineVariant,
                  tabs: categorias
                      .map((c) => Tab(icon: Icon(c.$3, size: 20), text: c.$2))
                      .toList(),
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: categorias.map((c) {
                    return _CategoriaTab(
                      categoria: c.$1,
                      settings: settings,
                      // tenantIdProvider respeta impersonación: si el
                      // super_admin está dentro de un tenant, retorna
                      // el tenant impersonado, no el System.
                      tenantId: ref.watch(tenantIdProvider) ?? '',
                      esAdmin: esAdmin,
                      esSuperAdmin: esSuperAdmin,
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Settings que se renderizan con widgets especiales o que están
// obsoletos/orphaned y no deben mostrarse al admin. Vive a nivel de archivo
// para que el catch-all de "Otros" lo respete (no re-mostrar orphans).
const _hidden = {
  'empresa.logo_path',
  // Legacy duplicados — la app ya usa los metodo_* de 0040.
  'pagos.transferencia_habilitada',
  'pagos.tarjeta_habilitada',
  // Orphaned — nunca leído por AppSettings.
  'cobranza.cargo_reconexion',
  // Modo de ruta: setting huérfano (0 usos en el código, sin getter). El
  // mapa del cobrador no lo lee. Se oculta hasta implementar ruta
  // planificada vs libre.
  'cobranza.modo_ruta',
  // Feature 'recrear pago' eliminada (#5): anular es void puro. El seed
  // en DB (0045/0051) queda orphaned y se oculta acá (no se migra).
  'cobranza.recrear_pago_anulado',
  // Templates sin implementar — confunden al admin.
  'recibo.template_57mm',
  'recibo.template_80mm',
  // Orden del pie: se edita con el widget ReorderableListView dedicado
  // (#8b), no como campo de texto CSV.
  'recibo.orden_pie',
  // Superseded por el diseñador de bloques (recibo.layout): la visibilidad
  // del logo/empresa/monto-en-letras ahora se controla desde el editor de
  // bloques, no con toggles sueltos. Se ocultan para no confundir.
  'recibo.imprimir_logo',
  'recibo.mostrar_empresa',
  'recibo.monto_en_letras',
  // El layout se edita con el diseñador visual, nunca como texto crudo.
  'recibo.layout',
  // Mismo caso que recibo.layout: JSON {tabla: [campos]} que se edita SÓLO con
  // la pantalla dedicada "Campos del historial" (audit_campos_screen, link en la
  // tab Avanzado). Como texto crudo se corrompe el change log. Lo crea esa
  // pantalla al vuelo (no está en ningún seed) — por eso se colaba al "Otros".
  'audit.campos_visibles',
  // Feature sin implementar (caja chica del cobrador: tabla + UI
  // pendientes). Se oculta hasta que exista la feature real.
  'caja_chica.habilitada',
};

// Settings que SOLO ve el super_admin. Hoy todos viven en la tab "Avanzado"
// (que de por sí sólo la ve el super_admin), pero mantenemos el guard por
// defensa en profundidad si un admin llegara a la sección.
const _superAdminOnly = {
  'cobranza.comprobante_habilitado',
  'cobranza.foto_obligatoria',
  // Pantallas admin opcionales: el super_admin las habilita por tenant.
  'cobranza.pantalla_pagos',
  'cobranza.pantalla_notificaciones',
  // Visibilidad del panel de Auditoría para el admin (0089): default OFF.
  'cobranza.audit_visible_admin',
  // Descuentos (manual en campo): módulo que el super_admin habilita por
  // tenant (0086). El admin no lo ve ni lo puede activar.
  'cobranza.descuentos_habilitados',
  'cobranza.descuento_tipo',
  'cobranza.descuento_max_monto',
  'cobranza.descuento_max_porcentaje',
  // Reconexión: ídem, super_admin-only por tenant (0086).
  'cobranza.cargo_reconexion_habilitado',
  'cobranza.monto_reconexion',
};

class _CategoriaTab extends ConsumerWidget {
  const _CategoriaTab({
    required this.categoria,
    required this.settings,
    required this.tenantId,
    required this.esAdmin,
    required this.esSuperAdmin,
  });

  final String categoria;
  final Map<String, Setting> settings;
  final String tenantId;
  final bool esAdmin;
  final bool esSuperAdmin;

  /// Guarda un setting y muestra el snackbar de confirmación.
  Future<void> _guardar(
    BuildContext context,
    WidgetRef ref,
    String clave,
    dynamic nuevo,
  ) async {
    await ref.read(settingsRepoProvider).update(tenantId, clave, nuevo);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_labelCorto(clave)} actualizado'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // La tab Recibos ES el diseñador completo (2 columnas: editor + preview en
    // vivo). Ocupa toda la altura; no usa los tiles genéricos ni grupos.
    if (categoria == 'recibos') {
      return ReciboLayoutEditor(tenantId: tenantId);
    }

    // ¿Puede ver/editar un setting? Respeta el guard super_admin-only.
    bool visible(String clave) =>
        !_hidden.contains(clave) &&
        (esSuperAdmin || !_superAdminOnly.contains(clave)) &&
        settings.containsKey(clave);

    // Construye las tarjetas-sección de la categoría, salteando grupos vacíos
    // (sin un solo setting presente/visible en el mapa sincronizado).
    final grupos = gruposDe(categoria);
    final cards = <Widget>[];

    for (final g in grupos) {
      final tarjeta = _construirGrupo(context, ref, g, visible);
      if (tarjeta != null) cards.add(tarjeta);
    }

    // Catch-all "Otros": cualquier setting de ESTA categoría que exista, no
    // esté hidden, sea visible para el rol, y NO lo reclame NINGÚN grupo (de
    // ninguna tab). El "ninguna tab" importa: los settings super_admin-only
    // tienen categoría DB 'cobranza' pero viven en grupos de la tab 'avanzado';
    // usar el set global evita que el "Otros" de Cobranza los duplique. Con la
    // data actual queda vacío; es una red de seguridad para no perder settings
    // nuevos que se agreguen sin asignarles grupo.
    final claimadas = clavesReclamadasGlobal();
    final huerfanas = settings.values
        .where((s) =>
            s.categoria == categoria &&
            visible(s.clave) &&
            !claimadas.contains(s.clave))
        .map((s) => s.clave)
        .toList()
      ..sort();
    if (huerfanas.isNotEmpty) {
      final otros = _GrupoCard(
        titulo: 'Otros',
        icono: Icons.more_horiz,
        children: [
          for (var i = 0; i < huerfanas.length; i++) ...[
            if (i > 0) const _SettingDivider(),
            _settingTile(context, ref, huerfanas[i]),
          ],
        ],
      );
      cards.add(otros);
    }

    // Avanzado: además de los grupos, el link a "Campos del historial".
    if (categoria == 'avanzado' && esSuperAdmin) {
      cards.add(const _HistorialCamposCard());
    }

    if (cards.isEmpty) {
      return const Center(child: Text('Sin opciones en esta categoría'));
    }

    // Layout: 1 columna (angosto) o 2 columnas (ancho, ≥900px). Centrado y
    // limitado a 1200px para que no se estire en ultrawide.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dosColumnas = constraints.maxWidth >= 900;

        // En Empresa, el widget de logo va arriba de TODO (ancho completo,
        // sólo admin). No entra en la grilla de 2 columnas.
        final logo = (categoria == 'empresa' && esAdmin)
            ? _LogoUploadWidget(tenantId: tenantId)
            : null;

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (logo != null) ...[
                    logo,
                    const SizedBox(height: 12),
                  ],
                  if (dosColumnas)
                    _grillaDosColumnas(cards)
                  else
                    ..._intercalar(cards),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Apila las tarjetas en 1 columna con separación vertical.
  List<Widget> _intercalar(List<Widget> cards) {
    final out = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 12));
      out.add(cards[i]);
    }
    return out;
  }

  /// Distribuye las tarjetas en 2 columnas alternando por índice par/impar.
  /// Cada columna es un Column independiente; arrancan alineadas arriba para
  /// que tarjetas de distinta altura no se estiren.
  Widget _grillaDosColumnas(List<Widget> cards) {
    final izquierda = <Widget>[];
    final derecha = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      final destino = i.isEven ? izquierda : derecha;
      if (destino.isNotEmpty) destino.add(const SizedBox(height: 12));
      destino.add(cards[i]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: izquierda,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: derecha,
          ),
        ),
      ],
    );
  }

  /// Construye una tarjeta-sección. Devuelve null si el grupo no tiene ningún
  /// setting visible/presente (no se renderiza un grupo vacío).
  Widget? _construirGrupo(
    BuildContext context,
    WidgetRef ref,
    SettingGroup g,
    bool Function(String) visible,
  ) {
    final filas = <Widget>[];

    for (final e in g.entradas) {
      if (e.tieneHijos) {
        // Entrada con dependencia padre→hijos. Si el padre no es visible, se
        // saltea el bloque completo (incl. hijos). Si lo es, se delega a un
        // widget stateful que trackea el toggle local para el reveal instantáneo.
        if (!visible(e.clave)) continue;
        final hijasVisibles =
            e.hijos.where(visible).toList(growable: false);
        if (filas.isNotEmpty) filas.add(const _SettingDivider());
        filas.add(_DependenciaRevelable(
          padre: settings[e.clave]!,
          hijos: [for (final h in hijasVisibles) settings[h]!],
          esAdmin: esAdmin,
          onGuardar: (clave, valor) => _guardar(context, ref, clave, valor),
        ));
      } else {
        // Setting plano.
        if (!visible(e.clave)) continue;
        if (filas.isNotEmpty) filas.add(const _SettingDivider());
        filas.add(_settingTile(context, ref, e.clave));
      }
    }

    if (filas.isEmpty) return null;
    return _GrupoCard(
      titulo: g.titulo,
      icono: g.icono,
      subtitulo: g.subtitulo,
      children: filas,
    );
  }

  /// Tile editor de un setting (toggle/number/text/dropdown) ya envuelto con
  /// guardado + snackbar. `puedeEditar` respeta admin vs admin_cobranza.
  Widget _settingTile(BuildContext context, WidgetRef ref, String clave) {
    final s = settings[clave]!;
    final puedeEditar = esAdmin || s.editablePor == 'admin_cobranza';
    return _SettingTile(
      setting: s,
      puedeEditar: puedeEditar,
      onSave: (nuevo) => _guardar(context, ref, clave, nuevo),
    );
  }
}

String _labelCorto(String clave) =>
    clave.split('.').last.replaceAll('_', ' ');

/// Tarjeta-sección: header (ícono + título + subtítulo opcional) y los settings
/// del grupo apilados, con separadores sutiles ya intercalados por el caller.
class _GrupoCard extends StatelessWidget {
  const _GrupoCard({
    required this.titulo,
    required this.icono,
    required this.children,
    this.subtitulo,
  });

  final String titulo;
  final IconData icono;
  final String? subtitulo;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header.
            Row(
              children: [
                Icon(icono, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titulo,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (subtitulo != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitulo!,
                            style: TextStyle(
                              color: scheme.outline,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Separador sutil entre settings dentro de un grupo.
class _SettingDivider extends StatelessWidget {
  const _SettingDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 18,
      thickness: 0.5,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
    );
  }
}

/// Tarjeta-link "Campos del historial" (tab Avanzado, super_admin). No es un
/// setting: navega a la pantalla de configuración del change log. La pantalla
/// destino igual defiende con su propio gate.
class _HistorialCamposCard extends StatelessWidget {
  const _HistorialCamposCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Avanzado',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune),
              title: const Text('Campos del historial'),
              subtitle: const Text(
                'Elegí qué campos se ven en el historial de cambios',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/admin/settings/historial-campos'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bloque "padre con hijos revelables": un toggle padre que muestra/oculta
/// (animado) los settings hijos según su estado. El estado del toggle se
/// trackea LOCAL para que el reveal sea instantáneo (no espera el round-trip a
/// la DB). El `didUpdateWidget` re-sincroniza si el valor del server cambia.
class _DependenciaRevelable extends StatefulWidget {
  const _DependenciaRevelable({
    required this.padre,
    required this.hijos,
    required this.esAdmin,
    required this.onGuardar,
  });

  final Setting padre;
  final List<Setting> hijos;
  final bool esAdmin;
  final Future<void> Function(String clave, dynamic valor) onGuardar;

  @override
  State<_DependenciaRevelable> createState() => _DependenciaRevelableState();
}

class _DependenciaRevelableState extends State<_DependenciaRevelable> {
  late bool _padreOn;

  @override
  void initState() {
    super.initState();
    _padreOn = widget.padre.asBool;
  }

  @override
  void didUpdateWidget(covariant _DependenciaRevelable old) {
    super.didUpdateWidget(old);
    // Si el valor del server cambió (ej. otra sesión), re-sincronizamos el
    // estado local del reveal.
    _padreOn = widget.padre.asBool;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final puedeEditarPadre =
        widget.esAdmin || widget.padre.editablePor == 'admin_cobranza';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Toggle padre. Al cambiar, actualizamos el estado local (reveal
        // instantáneo) y disparamos el guardado.
        _SettingTile(
          setting: widget.padre,
          puedeEditar: puedeEditarPadre,
          onSave: (nuevo) async {
            if (nuevo is bool && mounted) {
              setState(() => _padreOn = nuevo);
            }
            await widget.onGuardar(widget.padre.clave, nuevo);
          },
          // El tile notifica el cambio del switch ANTES del round-trip para
          // que el reveal no espere a la DB.
          onBoolChangedLocal: (v) {
            if (mounted) setState(() => _padreOn = v);
          },
        ),
        // Hijos revelables: ocultos cuando el padre está OFF (no sólo
        // disabled). AnimatedSize anima alto; el AnimatedOpacity suaviza.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: (_padreOn && widget.hijos.isNotEmpty)
                ? Padding(
                    key: const ValueKey('hijos-on'),
                    // Indentación + borde izquierdo sutil para marcar jerarquía.
                    padding: const EdgeInsets.only(top: 8, left: 12),
                    child: Container(
                      padding: const EdgeInsets.only(left: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: scheme.outlineVariant,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < widget.hijos.length; i++) ...[
                            if (i > 0) const _SettingDivider(),
                            _SettingTile(
                              setting: widget.hijos[i],
                              puedeEditar: widget.esAdmin ||
                                  widget.hijos[i].editablePor ==
                                      'admin_cobranza',
                              onSave: (nuevo) => widget.onGuardar(
                                  widget.hijos[i].clave, nuevo),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : const SizedBox(
                    key: ValueKey('hijos-off'),
                    width: double.infinity,
                  ),
          ),
        ),
      ],
    );
  }
}

class _SettingTile extends StatefulWidget {
  const _SettingTile({
    required this.setting,
    required this.puedeEditar,
    required this.onSave,
    this.onBoolChangedLocal,
  });

  final Setting setting;
  final bool puedeEditar;
  final Future<void> Function(dynamic) onSave;

  /// Callback opcional: se invoca con el nuevo valor del switch ANTES de
  /// guardar, para que el padre revele/oculte hijos sin esperar el round-trip.
  final void Function(bool)? onBoolChangedLocal;

  @override
  State<_SettingTile> createState() => _SettingTileState();
}

class _SettingTileState extends State<_SettingTile> {
  late TextEditingController _ctrl;
  late bool _boolValor;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.setting.valor?.toString() ?? '',
    );
    _boolValor = widget.setting.asBool;
  }

  @override
  void didUpdateWidget(covariant _SettingTile old) {
    super.didUpdateWidget(old);
    // Si llega nuevo valor del server y el campo no está enfocado, actualizamos.
    final nuevoTexto = widget.setting.valor?.toString() ?? '';
    if (nuevoTexto != _ctrl.text && !FocusScope.of(context).hasFocus) {
      _ctrl.text = nuevoTexto;
    }
    _boolValor = widget.setting.asBool;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _debouncedSave(dynamic valor) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      widget.onSave(valor);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;

    // Los booleanos se renderizan como un SwitchListTile compacto (título +
    // subtítulo + switch). El resto (number/text/dropdown) usa label arriba +
    // field denso abajo.
    if (s.tipo == 'boolean' && _dropdownFor(s.clave) == null) {
      return _boolTile();
    }
    return _fieldTile();
  }

  // ---- Render de un toggle (boolean) ----
  Widget _boolTile() {
    final s = widget.setting;
    final scheme = Theme.of(context).colorScheme;
    final label = _label(s.clave);
    final desc = _descripcionOverride(s.clave) ?? s.descripcion;

    // Efectivo es el método por defecto e inmutable: el toggle queda fijo en
    // ON y deshabilitado (no se puede dejar al cobrador sin métodos de pago).
    final esEfectivoFijo = s.clave == 'pagos.metodo_efectivo';
    final enabled = widget.puedeEditar && !esEfectivoFijo;
    final valor = esEfectivoFijo ? true : _boolValor;

    return SwitchListTile.adaptive(
      value: valor,
      onChanged: enabled
          ? (v) {
              setState(() => _boolValor = v);
              widget.onBoolChangedLocal?.call(v);
              widget.onSave(v);
            }
          : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 14.5),
            ),
          ),
          if (!widget.puedeEditar) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Sólo admin puede modificar',
              child: Icon(Icons.lock_outline, color: scheme.outline, size: 16),
            ),
          ],
        ],
      ),
      subtitle: (desc != null && desc.isNotEmpty)
          ? Text(desc, style: TextStyle(color: scheme.outline, fontSize: 12))
          : (esEfectivoFijo
              ? Text('Método por defecto, siempre activo',
                  style: TextStyle(color: scheme.outline, fontSize: 12))
              : null),
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
    );
  }

  // ---- Render de un campo (number / string / json / dropdown) ----
  Widget _fieldTile() {
    final s = widget.setting;
    final scheme = Theme.of(context).colorScheme;
    final label = _label(s.clave);
    final desc = _descripcionOverride(s.clave) ?? s.descripcion;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14.5),
                ),
              ),
              if (!widget.puedeEditar)
                Tooltip(
                  message: 'Sólo admin puede modificar',
                  child: Icon(Icons.lock_outline,
                      color: scheme.outline, size: 16),
                ),
            ],
          ),
          if (desc != null && desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                desc,
                style: TextStyle(color: scheme.outline, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          _editor(),
        ],
      ),
    );
  }

  Widget _editor() {
    final s = widget.setting;
    final enabled = widget.puedeEditar;

    // Dropdown especial para formato de recibo (number type).
    if (s.clave == 'recibo.formato_default_mm') {
      final current = (s.valor as num?)?.toInt() ?? 80;
      return DropdownButtonFormField<int>(
        value: current == 80 ? 80 : 58,
        decoration: const InputDecoration(isDense: true),
        items: const [
          DropdownMenuItem(value: 58, child: Text('58 mm (angosto)')),
          DropdownMenuItem(value: 80, child: Text('80 mm (estándar)')),
        ],
        onChanged: enabled ? (v) { if (v != null) widget.onSave(v); } : null,
      );
    }

    // Dropdowns para settings con opciones fijas.
    final dropdownOptions = _dropdownFor(s.clave);
    if (dropdownOptions != null) {
      final current = (s.valor as String?) ?? dropdownOptions.first.$1;
      final validValue = dropdownOptions.any((o) => o.$1 == current)
          ? current
          : dropdownOptions.first.$1;
      return DropdownButtonFormField<String>(
        value: validValue,
        decoration: const InputDecoration(isDense: true),
        items: dropdownOptions
            .map((o) => DropdownMenuItem(value: o.$1, child: Text(o.$2)))
            .toList(),
        onChanged: enabled
            ? (v) {
                if (v != null) widget.onSave(v);
              }
            : null,
      );
    }

    if (s.tipo == 'number') {
      return TextFormField(
        controller: _ctrl,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: const InputDecoration(isDense: true),
        onChanged: (v) {
          final n = num.tryParse(v);
          if (n != null) _debouncedSave(n);
        },
      );
    }

    // string o json: text plano (json se trata como texto avanzado).
    return TextFormField(
      controller: _ctrl,
      enabled: enabled,
      maxLines: s.tipo == 'json' ? 5 : 1,
      decoration: const InputDecoration(isDense: true),
      onChanged: (v) => _debouncedSave(v),
    );
  }

  // Overrides de descripción cuando el copy de la DB no alcanza
  // (ej. feature flags pendientes de implementación).
  String? _descripcionOverride(String clave) {
    return switch (clave) {
      'caja_chica.habilitada' =>
        'Permite asignar caja chica diaria al cobrador y reconciliar '
            'efectivo al final del día. (Feature en desarrollo)',
      'cobranza.audit_visible_admin' =>
        'Si está activo, el admin del tenant ve el panel de Auditoría '
            '(historial de cambios) en su menú. Apagado, sólo vos (super_admin) '
            'lo ves.',
      _ => null,
    };
  }

  // Etiquetas legibles para las claves más comunes.
  String _label(String clave) {
    const labels = <String, String>{
      'empresa.nombre': 'Nombre comercial',
      'empresa.direccion': 'Dirección',
      'empresa.telefono': 'Teléfono',
      'empresa.ruc': 'RUC',
      'empresa.logo_path': 'Path del logo',
      'empresa.whatsapp': 'WhatsApp',
      'cobranza.dias_gracia': 'Días de gracia',
      'cobranza.modo_ruta': 'Modo de ruta',
      'cobranza.descuentos_habilitados': 'Permitir descuentos',
      'cobranza.descuento_tipo': 'Tipo de descuento',
      'cobranza.descuento_max_porcentaje': 'Tope descuento %',
      'cobranza.descuento_max_monto': 'Tope descuento monto',
      'cobranza.cargo_reconexion_habilitado': 'Cobrar reconexión',
      'cobranza.cargo_reconexion': 'Monto reconexión automática',
      'cobranza.monto_reconexion': 'Monto de reconexión',
      'caja_chica.habilitada': 'Caja chica del cobrador',
      'audit.visible_admin_cobranza': 'Admin cobranza ve historial de cambios',
      'cobranza.cobrador_edita_fecha': 'Cobrador puede editar fecha',
      'cobranza.cobrador_anula_cobros': 'Cobrador puede anular cobros',
      'cobranza.cobrador_edita_cobros': 'Cobrador puede editar cobros',
      'cobranza.comprobante_habilitado': 'Habilitar foto de comprobante',
      'cobranza.foto_obligatoria': 'Foto comprobante obligatoria',
      'cobranza.pantalla_pagos': 'Pantalla de pagos del tenant (admin)',
      'cobranza.pantalla_notificaciones': 'Pantalla de notificaciones de mora',
      'cobranza.audit_visible_admin': 'Panel de Auditoría visible al admin',
      'cobranza.pago_parcial': 'Permitir pago parcial',
      'cobranza.pago_adelantado': 'Permitir pago adelantado (multi-cuota)',
      'cobranza.dias_cuotas_visibles': 'Días de cuotas visibles al cobrador',
      'pagos.transferencia_habilitada': 'Aceptar transferencias',
      'pagos.deposito_habilitado': 'Aceptar depósitos',
      'pagos.tarjeta_habilitada': 'Aceptar tarjeta',
      'pagos.metodo_efectivo': 'Aceptar efectivo',
      'pagos.metodo_transferencia': 'Aceptar transferencia',
      'pagos.metodo_tarjeta': 'Aceptar tarjeta',
      'pagos.usd_habilitado': 'Aceptar pagos en USD',
      'pagos.tasa_usd_cordoba': 'Tasa USD → C\$',
      'moneda.principal': 'Moneda principal',
      'recibo.formato_default_mm': 'Ancho de papel (mm)',
      'recibo.template_57mm': 'Template 57mm',
      'recibo.template_80mm': 'Template 80mm',
      'recibo.imprimir_logo': 'Imprimir logo en recibo',
      'recibo.pie_libre': 'Pie del recibo',
      'recibo.titulo': 'Título del recibo',
      'recibo.monto_en_letras': 'Monto en letras',
      'recibo.mostrar_adeudado': 'Mostrar saldo de la cuota',
      'recibo.mostrar_empresa': 'Mostrar datos de empresa',
      'recibo.mostrar_cedula': 'Mostrar cédula del cliente',
      'cuotas.manuales': 'Cuotas manuales',
      'cuotas.editar_monto': 'Editar monto de cuota',
      'cuotas.descuento_pronto_pago': 'Descuento pronto pago (valor)',
      'cuotas.descuento_pronto_pago_tipo': 'Tipo de descuento pronto pago',
    };
    return labels[clave] ?? _humanize(clave.split('.').last);
  }

  static String _humanize(String raw) {
    return raw
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
  }

  static List<(String, String)>? _dropdownFor(String clave) {
    return switch (clave) {
      'cuotas.descuento_pronto_pago_tipo' => [
        ('porcentaje', 'Porcentaje (%)'),
        ('monto', 'Monto fijo (C\$)'),
      ],
      'cobranza.descuento_tipo' => [
        ('monto', 'Monto fijo'),
        ('porcentaje', 'Porcentaje'),
        ('ambos', 'Ambos'),
      ],
      'cobranza.modo_ruta' => [
        ('libre', 'Libre'),
        ('planificada', 'Planificada'),
      ],
      'moneda.principal' => [
        ('NIO', 'Córdobas (NIO)'),
        ('USD', 'Dólares (USD)'),
      ],
      _ => null,
    };
  }
}

/// Widget de upload del logo de la empresa. Se muestra al inicio de la
/// tab "Empresa" cuando el usuario tiene permiso de admin.
///
/// Flujo:
/// 1. Muestra preview del logo actual (URL firmada vía `logoEmpresaUrlProvider`)
///    o un placeholder si no hay logo.
/// 2. Botón "Subir logo" abre el image picker.
/// 3. Al seleccionar imagen, sube a Storage y guarda el path en
///    `empresa.logo_path` vía `settingsRepo.update`.
/// 4. El provider se invalida y la URL firmada se refresca.
class _LogoUploadWidget extends ConsumerStatefulWidget {
  const _LogoUploadWidget({required this.tenantId});
  final String tenantId;

  @override
  ConsumerState<_LogoUploadWidget> createState() => _LogoUploadWidgetState();
}

class _LogoUploadWidgetState extends ConsumerState<_LogoUploadWidget> {
  bool _subiendo = false;
  String? _error;

  Future<void> _subirLogo() async {
    setState(() {
      _subiendo = true;
      _error = null;
    });
    try {
      final service = ref.read(logoEmpresaServiceProvider);
      final path = await service.pickYSubir(tenantId: widget.tenantId);
      if (path == null) {
        // Usuario canceló el picker.
        setState(() => _subiendo = false);
        return;
      }
      // Guardar el path en settings.
      await ref.read(settingsRepoProvider).update(
            widget.tenantId,
            'empresa.logo_path',
            path,
          );
      // Invalidar el provider para refrescar la URL firmada.
      ref.invalidate(logoEmpresaUrlProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logo actualizado')),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  Future<void> _eliminarLogo() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar logo'),
        content: const Text('¿Seguro que querés eliminar el logo de la empresa?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmar != true) return;

    setState(() {
      _subiendo = true;
      _error = null;
    });
    try {
      final settings = ref.read(appSettingsProvider);
      final currentPath = settings.empresaLogoPath;
      if (currentPath.isNotEmpty) {
        final service = ref.read(logoEmpresaServiceProvider);
        await service.eliminar(currentPath);
      }
      // Limpiar el path en settings (null serializado como JSON).
      await ref.read(settingsRepoProvider).update(
            widget.tenantId,
            'empresa.logo_path',
            null,
          );
      ref.invalidate(logoEmpresaUrlProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logo eliminado')),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logoUrlAsync = ref.watch(logoEmpresaUrlProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.image, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Logo de la empresa',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Se muestra en el recibo de cobro.',
                          style:
                              TextStyle(color: scheme.outline, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 12),
            const SizedBox(height: 4),

            // Preview del logo o placeholder.
            Center(
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                  color: scheme.surfaceContainerHighest,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: logoUrlAsync.when(
                    data: (url) {
                      if (url == null) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.image_outlined,
                                  size: 48, color: scheme.outline),
                              const SizedBox(height: 8),
                              Text('Sin logo',
                                  style: TextStyle(
                                      color: scheme.outline, fontSize: 13)),
                            ],
                          ),
                        );
                      }
                      return Image.network(
                        url,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return const Center(
                              child: CircularProgressIndicator(strokeWidth: 2));
                        },
                        errorBuilder: (_, __, ___) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.broken_image,
                                  size: 48, color: scheme.error),
                              const SizedBox(height: 8),
                              Text('Error al cargar',
                                  style: TextStyle(
                                      color: scheme.error, fontSize: 13)),
                            ],
                          ),
                        ),
                      );
                    },
                    loading: () => const Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    error: (_, __) => Center(
                      child: Icon(Icons.error_outline,
                          size: 48, color: scheme.error),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),

            // Botones de acción.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _subiendo ? null : _subirLogo,
                  icon: _subiendo
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload),
                  label: Text(_subiendo ? 'Subiendo...' : 'Subir logo'),
                ),
                // Botón eliminar solo si hay logo.
                if (ref.read(appSettingsProvider).empresaLogoPath.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _subiendo ? null : _eliminarLogo,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Eliminar'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
