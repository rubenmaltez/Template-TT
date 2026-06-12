import 'package:flutter/material.dart';

/// Chip desplegable reutilizable: chip redondeado con ícono +
/// "Etiqueta: selección ▾". Abre un menú con "Todos/Todas" (value null)
/// + las opciones. Se resalta (primaryContainer) cuando hay un filtro
/// activo.
///
/// Usado por el filtro por cobrador/zona del mapa (`mapa_screen.dart`) y
/// por la vista admin de Cobros (`cuotas_list_screen.dart`). Mantiene el
/// look consistente entre ambas pantallas.
class DropdownFiltro extends StatelessWidget {
  const DropdownFiltro({
    super.key,
    required this.icon,
    required this.hint,
    required this.todosLabel,
    required this.value,
    required this.opciones,
    required this.onChanged,
  });

  final IconData icon;
  final String hint;
  final String todosLabel;
  final String? value;
  final List<({String id, String label})> opciones;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Si el value seleccionado ya no está entre las opciones (ej. el
    // filtrado dejó de tener filas), caemos a null.
    final valido =
        value != null && opciones.any((o) => o.id == value) ? value : null;
    final activo = valido != null;
    final seleccion =
        activo ? opciones.firstWhere((o) => o.id == valido).label : todosLabel;

    return PopupMenuButton<String>(
      tooltip: hint,
      position: PopupMenuPosition.under,
      onSelected: (val) => onChanged(val == '__TODOS__' ? null : val),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: '__TODOS__',
          child: _MenuRow(label: todosLabel, seleccionado: !activo),
        ),
        if (opciones.isNotEmpty) const PopupMenuDivider(),
        for (final o in opciones)
          PopupMenuItem<String>(
            value: o.id,
            child: _MenuRow(label: o.label, seleccionado: o.id == valido),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        decoration: BoxDecoration(
          color: activo ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: activo ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: activo
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              '$hint: $seleccion',
              style: TextStyle(
                fontSize: 13,
                fontWeight: activo ? FontWeight.w600 : FontWeight.normal,
                color: activo ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
            Icon(Icons.arrow_drop_down,
                size: 18,
                color: activo
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Ítem del menú del chip desplegable: check a la izquierda si está elegido.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.seleccionado});

  final String label;
  final bool seleccionado;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          child: seleccionado
              ? Icon(Icons.check, size: 18, color: scheme.primary)
              : null,
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
