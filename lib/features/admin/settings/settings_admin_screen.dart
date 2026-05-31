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
import 'recibo_preview.dart';

/// Panel de configuración. Agrupa settings por categoría en pestañas.
/// Sólo admin puede editar la mayoría; admin_cobranza puede tocar las
/// settings marcadas con editable_por='admin_cobranza' (ej. tasa USD).
class SettingsAdminScreen extends ConsumerWidget {
  const SettingsAdminScreen({super.key});

  static const _categorias = [
    ('empresa', 'Empresa', Icons.business),
    ('cobranza', 'Cobranza', Icons.receipt_long),
    ('pagos', 'Pagos', Icons.payments),
    ('moneda', 'Moneda', Icons.currency_exchange),
    ('cuotas', 'Cuotas', Icons.calendar_month),
    ('recibos', 'Recibos', Icons.print),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsMapProvider);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    // super_admin hereda permisos de admin.
    final esAdmin = cobrador?.tieneAccesoAdmin ?? false;
    final esSuperAdmin = cobrador?.esSuperAdmin ?? false;

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
          length: _categorias.length,
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
                  tabs: _categorias
                      .map((c) => Tab(icon: Icon(c.$3, size: 20), text: c.$2))
                      .toList(),
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: _categorias.map((c) {
                    final delCat = settings.values
                        .where((s) => s.categoria == c.$1)
                        .toList();
                    return _CategoriaTab(
                      categoria: c.$1,
                      settings: delCat,
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

class _CategoriaTab extends ConsumerWidget {
  const _CategoriaTab({
    required this.categoria,
    required this.settings,
    required this.tenantId,
    required this.esAdmin,
    required this.esSuperAdmin,
  });

  final String categoria;
  final List<Setting> settings;
  final String tenantId;
  final bool esAdmin;
  final bool esSuperAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (settings.isEmpty) {
      return const Center(child: Text('Sin opciones en esta categoría'));
    }

    // Filtrar settings que se renderizan con widgets especiales o que
    // están obsoletos/orphaned y no deben mostrarse al admin.
    const _hidden = {
      'empresa.logo_path',
      // Legacy duplicados — la app ya usa los metodo_* de 0040.
      'pagos.transferencia_habilitada',
      'pagos.tarjeta_habilitada',
      // Orphaned — nunca leído por AppSettings.
      'cobranza.cargo_reconexion',
      // Feature 'recrear pago' eliminada (#5): anular es void puro. El seed
      // en DB (0045/0051) queda orphaned y se oculta acá (no se migra).
      'cobranza.recrear_pago_anulado',
      // Templates sin implementar — confunden al admin.
      'recibo.template_57mm',
      'recibo.template_80mm',
    };
    final settingsFiltrados = settings
        .where((s) => !_hidden.contains(s.clave))
        .toList();

    // Orden lógico en vez de alfabético.
    settingsFiltrados.sort((a, b) {
      final oa = _sortOrder(a.clave);
      final ob = _sortOrder(b.clave);
      if (oa != ob) return oa.compareTo(ob);
      return a.clave.compareTo(b.clave);
    });

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Widget de logo al inicio de la tab Empresa.
        if (categoria == 'empresa' && esAdmin)
          _LogoUploadWidget(tenantId: tenantId),
        // Vista previa EN VIVO del recibo al inicio de la tab Recibos (#8a).
        if (categoria == 'recibos') const ReciboPreview(),
        ...settingsFiltrados.map((s) {
          final puedeEditar = esAdmin || s.editablePor == 'admin_cobranza';
          return _SettingTile(
            setting: s,
            puedeEditar: puedeEditar,
            onSave: (nuevo) async {
              await ref.read(settingsRepoProvider).update(tenantId, s.clave, nuevo);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${_labelCorto(s.clave)} actualizado'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
          );
        }),
        // Entrada al panel de campos del historial (Fase C). Oculta salvo
        // para super_admin; la pantalla destino igual defiende con un gate.
        if (categoria == 'cobranza' && esSuperAdmin) ...[
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Campos del historial'),
              subtitle: const Text(
                'Elegí qué campos se ven en el historial de cambios',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/admin/settings/historial-campos'),
            ),
          ),
        ],
      ],
    );
  }
}

String _labelCorto(String clave) =>
    clave.split('.').last.replaceAll('_', ' ');

class _SettingTile extends StatefulWidget {
  const _SettingTile({
    required this.setting,
    required this.puedeEditar,
    required this.onSave,
  });

  final Setting setting;
  final bool puedeEditar;
  final Future<void> Function(dynamic) onSave;

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
    final label = _label(s.clave);
    // Override de descripción para settings con copy específico de UI.
    // El descripcion de la DB se usa por default, pero algunos toggles
    // necesitan copy más amigable (ej. caja_chica marca "Feature en desarrollo"
    // mientras la implementación real está pendiente — ver migración 0063).
    final desc = _descripcionOverride(s.clave) ?? s.descripcion;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                      if (desc != null && desc.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            desc,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!widget.puedeEditar)
                  Tooltip(
                    message: 'Sólo admin puede modificar',
                    child: Icon(Icons.lock_outline,
                        color: Theme.of(context).colorScheme.outline,
                        size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _editor(),
          ],
        ),
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
        value: current == 57 ? 57 : 80,
        decoration: const InputDecoration(isDense: true),
        items: const [
          DropdownMenuItem(value: 57, child: Text('57 mm (angosto)')),
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

    if (s.tipo == 'boolean') {
      return SwitchListTile.adaptive(
        title: Text(_boolValor ? 'Activado' : 'Desactivado'),
        contentPadding: EdgeInsets.zero,
        value: _boolValor,
        onChanged: enabled
            ? (v) {
                setState(() => _boolValor = v);
                widget.onSave(v);
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
      'cobranza.foto_obligatoria': 'Foto comprobante obligatoria',
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
      'recibo.mostrar_adeudado': 'Mostrar meses adeudados',
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

int _sortOrder(String clave) {
  const order = <String, int>{
    // Empresa
    'empresa.nombre': 0,
    'empresa.direccion': 1,
    'empresa.telefono': 2,
    'empresa.ruc': 3,
    'empresa.whatsapp': 4,
    // Cobranza — fundamentales primero
    'cobranza.dias_gracia': 0,
    'cobranza.modo_ruta': 1,
    'cobranza.pago_parcial': 2,
    'cobranza.pago_adelantado': 3,
    'cobranza.foto_obligatoria': 4,
    // Cobrador permisos
    'cobranza.cobrador_edita_fecha': 10,
    'cobranza.cobrador_anula_cobros': 11,
    'cobranza.cobrador_edita_cobros': 12,
    // Descuentos (toggle padre → hijos)
    'cobranza.descuentos_habilitados': 20,
    'cobranza.descuento_tipo': 21,
    'cobranza.descuento_max_monto': 22,
    'cobranza.descuento_max_porcentaje': 23,
    'cobranza.dias_cuotas_visibles': 5,
    // Reconexión (toggle padre → valor)
    'cobranza.cargo_reconexion_habilitado': 30,
    'cobranza.monto_reconexion': 31,
    // Feature flag — feature real pendiente (ver migración 0063).
    'caja_chica.habilitada': 40,
    // Pagos
    'pagos.metodo_efectivo': 0,
    'pagos.metodo_transferencia': 1,
    'pagos.deposito_habilitado': 2,
    'pagos.metodo_tarjeta': 3,
    'pagos.usd_habilitado': 10,
    'pagos.tasa_usd_cordoba': 11,
    // Moneda
    'moneda.principal': 0,
    // Cuotas
    'cuotas.manuales': 0,
    'cuotas.editar_monto': 1,
    'cuotas.descuento_pronto_pago': 10,
    'cuotas.descuento_pronto_pago_tipo': 11,
    // Recibos
    'recibo.titulo': 0,
    'recibo.formato_default_mm': 1,
    'recibo.imprimir_logo': 2,
    'recibo.monto_en_letras': 3,
    'recibo.mostrar_adeudado': 4,
    'recibo.pie_libre': 5,
  };
  return order[clave] ?? 99;
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
            const Text(
              'Logo de la empresa',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              'Se muestra en el recibo de cobro.',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
            const SizedBox(height: 12),

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
