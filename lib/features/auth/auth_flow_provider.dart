import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tipo de flujo de auth detectado al arrancar la app desde un link de
/// email (recovery / invite).
///
/// El valor se captura en `main.dart` ANTES de `Supabase.initialize`,
/// porque la SDK procesa y limpia el fragmento de la URL durante la
/// inicialización (queda inaccesible después).
///
/// Posibles valores:
///   - 'recovery'  → el user clickeó "olvidé mi contraseña"
///   - 'invite'    → primer login después de ser invitado
///   - 'signup'    → confirmación de email tras signup público (no usado
///                   en este SaaS B2B)
///   - null        → arranque normal (sin link de email)
///
/// El router lo lee en su redirect para mandar al user a `/set-password`
/// cuando aplica. La pantalla SetPasswordScreen lo setea a null tras
/// guardar la nueva contraseña con éxito, así no queda en redirect loop.
final initialAuthFlowProvider = StateProvider<String?>((ref) => null);
