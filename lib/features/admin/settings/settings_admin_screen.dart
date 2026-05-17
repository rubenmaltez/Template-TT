import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/setting.dart';
import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
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
    ('recibos', 'Recibos', Icons.print),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsMapProvider);
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;
    final esAdmin = cobrador?.esAdmin ?? false;

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
                  tabs: _categorias
                      .map((c) => Tab(icon: Icon(c.$3), text: c.$2))
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
                      settings: delCat,
                      tenantId: cobrador?.tenantId ?? '',
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
    required this.settings,
    required this.tenantId,
    required this.esAdmin,
  });

  final List<Setting> settings;
  final String tenantId;
  final bool esAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (settings.isEmpty) {
      return const Center(child: Text('Sin opciones en esta categoría'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: settings.map((s) {
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
      }).toList(),
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
    };
    return labels[clave] ?? clave.split('.').last;
  }
}
