/// Helpers compartidos para renderizar info de cobradores y tenants. Antes
/// vivían duplicados en cada pantalla del panel super_admin; los movimos
/// acá para que cambiar un label sólo requiera tocar un archivo.

/// Iniciales para CircleAvatar a partir de un nombre. Devuelve una o dos
/// letras (primera de la primera palabra + primera de la última); '?' si
/// el string está vacío o sólo tiene whitespace. Tolerante a espacios
/// múltiples.
String initialsFromName(String s) {
  final parts =
      s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

/// Label legible del rol (el código vive en DB como snake_case). Fallback
/// al string crudo si aparece un rol que no conocemos — preferible a
/// mostrar nada si en el futuro se agrega un rol nuevo.
String rolLabel(String rol) => switch (rol) {
      'super_admin' => 'Super Admin',
      'admin' => 'Administrador',
      'admin_cobranza' => 'Admin de cobranza',
      'cobrador' => 'Cobrador',
      _ => rol,
    };

/// Variante de [rolLabel] que tolera null — se usa al renderizar valores
/// históricos de audit_log donde el campo puede no estar seteado.
String rolLabelOrDash(String? rol) => rol == null ? '—' : rolLabel(rol);
