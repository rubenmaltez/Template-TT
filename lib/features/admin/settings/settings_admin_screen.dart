import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/setting.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/providers/logo_empresa_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/services/logo_empresa_service.dart';
import '../../shared/widgets/empty_state.dart';

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
  });

  final String categoria;
  final List<Setting> settings;
  final String tenantId;
  final bool esAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (settings.isEmpty) {
      return const Center(child: Text('Sin opciones en esta categoría'));
    }

    // Filtrar el setting de logo_path: lo rendereamos con un widget
    // especial en vez del TextFormField genérico.
    final settingsFiltrados = settings
        .where((s) => s.clave != 'empresa.logo_path')
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Widget de logo al inicio de la tab Empresa.
        if (categoria == 'empresa' && esAdmin)
          _LogoUploadWidget(tenantId: tenantId),
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
    final desc = s.descripcion;

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

    // Dropdown especial para tipo de descuento pronto pago.
    if (s.clave == 'cuotas.descuento_pronto_pago_tipo') {
      final current = (s.valor as String?) ?? 'porcentaje';
      return DropdownButtonFormField<String>(
        value: current == 'monto' ? 'monto' : 'porcentaje',
        decoration: const InputDecoration(isDense: true),
        items: const [
          DropdownMenuItem(value: 'porcentaje', child: Text('Porcentaje (%)')),
          DropdownMenuItem(value: 'monto', child: Text('Monto fijo (C\$)')),
        ],
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

  // Etiquetas legibles para las claves más comunes.
  String _label(String clave) {
    const labels = <String, String>{
      'empresa.nombre': 'Nombre comercial',
      'empresa.direccion': 'Dirección',
      'empresa.telefono': 'Teléfono',
      'empresa.ruc': 'RUC',
      'empresa.logo_path': 'Path del logo',
      'cobranza.dias_gracia': 'Días de gracia',
      'cobranza.modo_ruta': 'Modo de ruta',
      'cobranza.descuentos_habilitados': 'Permitir descuentos',
      'cobranza.descuento_tipo': 'Tipo de descuento',
      'cobranza.descuento_max_porcentaje': 'Tope descuento %',
      'cobranza.descuento_max_monto': 'Tope descuento monto',
      'cobranza.cargo_reconexion_habilitado': 'Cobrar reconexión',
      'cobranza.cargo_reconexion': 'Monto reconexión automática',
      'cobranza.monto_reconexion': 'Monto de reconexión',
      'pagos.transferencia_habilitada': 'Aceptar transferencias',
      'pagos.deposito_habilitado': 'Aceptar depósitos',
      'pagos.tarjeta_habilitada': 'Aceptar tarjeta',
      'pagos.usd_habilitado': 'Aceptar pagos en USD',
      'pagos.tasa_usd_cordoba': 'Tasa USD → C\$',
      'recibo.formato_default_mm': 'Ancho de papel (mm)',
      'recibo.template_57mm': 'Template 57mm',
      'recibo.template_80mm': 'Template 80mm',
      'recibo.imprimir_logo': 'Imprimir logo en recibo',
      'recibo.pie_libre': 'Pie del recibo',
      'cuotas.manuales': 'Cuotas manuales',
      'cuotas.editar_monto': 'Editar monto de cuota',
      'cuotas.descuento_pronto_pago': 'Descuento pronto pago (valor)',
      'cuotas.descuento_pronto_pago_tipo': 'Tipo de descuento pronto pago',
    };
    return labels[clave] ?? clave.split('.').last;
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
