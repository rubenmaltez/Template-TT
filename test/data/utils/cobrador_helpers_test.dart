import 'package:flutter_test/flutter_test.dart';
import 'package:isp_billing/data/utils/cobrador_helpers.dart';

/// Tests de cobrador_helpers — funciones puras de presentación usadas en
/// el panel super_admin (CircleAvatar initials, labels de rol). Si rompe,
/// los avatares muestran basura o los roles aparecen con label incorrecto.
void main() {
  group('initialsFromName', () {
    test('nombre y apellido devuelve dos iniciales en mayúscula', () {
      expect(initialsFromName('Rubén Maltez'), 'RM');
    });

    test('nombre simple devuelve una sola inicial', () {
      expect(initialsFromName('Admin'), 'A');
    });

    test('string vacío devuelve ?', () {
      expect(initialsFromName(''), '?');
    });

    test('solo whitespace devuelve ?', () {
      expect(initialsFromName('   '), '?');
      expect(initialsFromName('\t\n'), '?');
    });

    test('nombre con tres o más palabras toma primera y última', () {
      expect(initialsFromName('Juan Carlos Pérez'), 'JP');
    });

    test('espacios múltiples entre palabras se toleran', () {
      expect(initialsFromName('  María   López  '), 'ML');
    });

    test('nombre con una sola letra', () {
      expect(initialsFromName('R'), 'R');
    });

    test('minúsculas se convierten a mayúsculas', () {
      expect(initialsFromName('ana ruiz'), 'AR');
    });
  });

  group('rolLabel', () {
    test('super_admin devuelve Super Admin', () {
      expect(rolLabel('super_admin'), 'Super Admin');
    });

    test('admin devuelve Administrador', () {
      expect(rolLabel('admin'), 'Administrador');
    });

    test('admin_cobranza devuelve Admin de cobranza', () {
      expect(rolLabel('admin_cobranza'), 'Admin de cobranza');
    });

    test('cobrador devuelve Cobrador', () {
      expect(rolLabel('cobrador'), 'Cobrador');
    });

    test('rol desconocido devuelve el string crudo (fallback)', () {
      expect(rolLabel('viewer'), 'viewer');
      expect(rolLabel('manager'), 'manager');
    });

    test('string vacío devuelve string vacío (fallback sin crash)', () {
      expect(rolLabel(''), '');
    });
  });

  group('rolLabelOrDash', () {
    test('null devuelve dash (—)', () {
      expect(rolLabelOrDash(null), '—');
    });

    test('rol válido delega a rolLabel', () {
      expect(rolLabelOrDash('admin'), 'Administrador');
      expect(rolLabelOrDash('cobrador'), 'Cobrador');
    });

    test('rol desconocido devuelve el string crudo via rolLabel', () {
      expect(rolLabelOrDash('nuevo_rol'), 'nuevo_rol');
    });
  });
}
