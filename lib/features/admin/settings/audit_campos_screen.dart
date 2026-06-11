import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers/cobrador_provider.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/utils/audit_changelog.dart';
import '../../shared/widgets/empty_state.dart';
import '../../../data/utils/errores.dart';

/// Panel de configuración del CHANGE LOG (Fase C). El super_admin elige, por
/// entidad, qué campos aparecen en el historial de cambios (`HistorialCambios`
/// y `HistorialCuota`). La selección se guarda en el setting per-tenant
/// `audit.campos_visibles` (map JSONB `{tabla: [campos]}`).
///
/// Si una entidad no tiene config guardada, el widget de historial cae al
/// default curado (`kAuditCamposVisiblesDefault`). El estado inicial de cada
/// checkbox refleja eso: la config guardada si existe, sino el default.
///
/// Gate: sólo super_admin. La entrada en Settings está oculta para el resto;
/// igual defendemos acá con un EmptyState.
class AuditCamposScreen extends ConsumerStatefulWidget {
  const AuditCamposScreen({super.key});

  @override
  ConsumerState<AuditCamposScreen> createState() => _AuditCamposScreenState();
}

class _AuditCamposScreenState extends ConsumerState<AuditCamposScreen> {
  // Estado local de la selección: {tabla: {campos marcados}}.
  // Se inicializa la primera vez desde la config/default y luego lo maneja
  // el usuario con los checkboxes.
  Map<String, Set<String>>? _seleccion;
  bool _guardando = false;

  /// Construye el estado inicial: para cada entidad del catálogo, los campos
  /// marcados son los de la config guardada (si la entidad está presente) o
  /// los del default curado.
  Map<String, Set<String>> _estadoInicial(Map<String, Set<String>> cfg) {
    final out = <String, Set<String>>{};
    for (final tabla in kAuditCamposCatalogo.keys) {
      final desdeConfig = cfg[tabla];
      if (desdeConfig != null) {
        // Solo conservamos campos que siguen estando en el catálogo (defensa
        // contra config vieja con campos que ya no existen).
        final catalogo = kAuditCamposCatalogo[tabla]!.toSet();
        out[tabla] = desdeConfig.where(catalogo.contains).toSet();
      } else {
        out[tabla] = {...?kAuditCamposVisiblesDefault[tabla]};
      }
    }
    return out;
  }

  Future<void> _guardar() async {
    final seleccion = _seleccion;
    if (seleccion == null) return;
    final tenantId = ref.read(tenantIdProvider);
    if (tenantId == null || tenantId.isEmpty) return;

    setState(() => _guardando = true);
    try {
      // Armamos el map {tabla: [campos]} respetando el orden del catálogo.
      final valor = <String, List<String>>{};
      for (final tabla in kAuditCamposCatalogo.keys) {
        final marcados = seleccion[tabla] ?? const <String>{};
        valor[tabla] = kAuditCamposCatalogo[tabla]!
            .where(marcados.contains)
            .toList();
      }
      await ref.read(settingsRepoProvider).upsert(
            tenantId,
            'audit.campos_visibles',
            valor,
            tipo: 'json',
            categoria: 'cobranza',
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Campos del historial guardados')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensajeErrorHumano(e, contexto: 'guardar'))),
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cobrador = ref.watch(cobradorActualProvider).valueOrNull;

    // Gate: sólo super_admin. La entrada en Settings está oculta para el resto.
    if (cobrador != null && !cobrador.esSuperAdmin) {
      return const EmptyState(
        icon: Icons.lock_outline,
        titulo: 'Acceso restringido',
        descripcion: 'Solo el super administrador puede configurar esto.',
      );
    }

    // Esperamos a que los settings hayan sincronizado antes de inicializar la
    // selección. Si arrancáramos con el provider vacío, los checkboxes caerían
    // a los defaults y, al guardar, pisarían la config guardada del tenant.
    final settingsAsync = ref.watch(settingsMapProvider);
    if (!settingsAsync.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    // Inicializamos la selección una vez, ya con los settings cargados.
    _seleccion ??= _estadoInicial(
      ref.read(appSettingsProvider).auditCamposVisibles,
    );
    final seleccion = _seleccion!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tune, color: scheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Qué se ve en el historial de cambios',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Elegí, por entidad, qué campos aparecen en el historial '
                    'de cambios (clientes, contratos, cuotas, pagos, etc.). '
                    'Si dejás una entidad sin tocar, se usan los campos '
                    'recomendados por defecto. Esta configuración aplica a '
                    'este tenant.',
                    style: TextStyle(color: scheme.outline, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ...kAuditCamposCatalogo.keys.map((tabla) {
            final campos = kAuditCamposCatalogo[tabla]!;
            final marcados = seleccion[tabla] ?? <String>{};
            final label = kAuditEntidadLabel[tabla] ?? tabla;
            return Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: Icon(Icons.history, color: scheme.primary),
                title: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${marcados.length} de ${campos.length} campos visibles',
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
                children: campos.map((campo) {
                  return CheckboxListTile(
                    dense: true,
                    title: Text(auditFieldLabel(campo)),
                    value: marcados.contains(campo),
                    onChanged: (v) {
                      setState(() {
                        final set = seleccion.putIfAbsent(
                          tabla,
                          () => <String>{},
                        );
                        if (v == true) {
                          set.add(campo);
                        } else {
                          set.remove(campo);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            );
          }),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _guardando ? null : _guardar,
            icon: _guardando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(_guardando ? 'Guardando...' : 'Guardar'),
          ),
        const SizedBox(height: 32),
      ],
    );
  }
}
