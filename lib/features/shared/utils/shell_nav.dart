import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Helpers de navegación de los shells (`AdminShell`, `AppShell`,
/// `SuperShell`).
///
/// **Problema que resuelve**: `showDialog` imperativo monta un
/// `DialogRoute` (subclase de `PopupRoute`) en el Navigator del
/// `ShellRoute`. Cuando se cambia de ruta dentro del shell vía
/// `context.go(...)`, go_router actualiza la `matchedLocation` y rebuilda
/// el child, **pero NO desmonta los modales abiertos**. El user ve el
/// dialog flotando sobre la nueva pantalla — UX confusa.
///
/// **Cómo lo resuelve**: antes de navegar, popUntil cierra modales
/// **descartables** (los que tienen `barrierDismissible: true`, el
/// default). `DialogRoute` / `ModalBottomSheetRoute` son `PopupRoute`,
/// no `PageRoute`, así que normalmente caen.
///
/// **Respeta `barrierDismissible: false`**: hay dialogs críticos en el
/// repo (CredencialesDialog que muestra password generada UNA vez,
/// dialogs de acciones destructivas como forzar-password / eliminar
/// cobrador) marcados explícitamente como no descartables. Si el helper
/// los popeara, el user podría perder la password generada con un click
/// accidental al sidebar — peor UX que el bug original. En ese caso, el
/// helper NO navega y muestra un SnackBar pidiéndole al user que cierre
/// el dialog primero explícitamente.
extension ShellNav on BuildContext {
  /// Navega a [path] cerrando primero cualquier dialog/sheet descartable
  /// que esté abierto. Si hay un dialog crítico (barrierDismissible:
  /// false), aborta la navegación y muestra un SnackBar.
  void closeModalsAndGo(String path) {
    if (_tryCloseDismissibleModals(this)) {
      go(path);
    } else {
      _showCloseFirstSnackBar(this);
    }
  }

  /// Ejecuta [action] (típicamente abrir otro dialog) cerrando primero
  /// modales descartables. Si hay uno crítico, aborta y notifica.
  void closeModalsThenRun(VoidCallback action) {
    if (_tryCloseDismissibleModals(this)) {
      action();
    } else {
      _showCloseFirstSnackBar(this);
    }
  }
}

/// popUntil cerrando solo modales descartables. Retorna `true` si el
/// stack quedó limpio (puede navegar), `false` si encontró un modal
/// crítico (barrierDismissible: false) y no debe pasar por arriba.
///
/// `PageRoute` siempre se conserva — esa es la ruta del shell route
/// activa.
bool _tryCloseDismissibleModals(BuildContext context) {
  var foundCritical = false;
  Navigator.of(context).popUntil((route) {
    if (route is PageRoute) return true; // ruta del shell, conservar
    if (route is PopupRoute && !route.barrierDismissible) {
      // Dialog crítico explícito (CredencialesDialog, confirmaciones
      // destructivas). NO popear — el user debe descartarlo a mano.
      foundCritical = true;
      return true;
    }
    return false; // popear modales descartables
  });
  return !foundCritical;
}

void _showCloseFirstSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Cerrá el diálogo abierto primero. La acción que pediste no '
        'se puede hacer sin descartarlo.',
      ),
      duration: Duration(seconds: 4),
    ),
  );
}
