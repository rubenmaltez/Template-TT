import 'package:flutter/services.dart';

/// Parseo TOLERANTE de montos tipeados (fix M8 del audit 2026-06-11): en
/// teclados Android con locale español la tecla decimal emite ','; el
/// formatter viejo `[0-9.]` la DESCARTABA en silencio y "500,50" se volvía
/// "50050" (monto_original inflado, vuelto gigante). Acepta coma o punto
/// como separador decimal (uno solo) y rechaza todo lo demás.
double? parseMonto(String? s) {
  if (s == null) return null;
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty || '.'.allMatches(t).length > 1) return null;
  return double.tryParse(t);
}

/// Formatter estándar para campos de monto: dígitos y separador (. o ,).
/// SIEMPRE en pareja con [parseMonto] (que normaliza y valida).
final montoInputFormatter =
    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));
