import 'package:excel/excel.dart';

import '../descarga_archivo.dart';

/// Construye un archivo Excel (.xlsx) de UNA hoja con encabezado + filas y lo
/// ofrece para descargar/guardar vía [guardarArchivo] (diálogo "Guardar como"
/// en Windows, selector de ubicación en Android).
///
/// Pensado para los reportes del admin: reutiliza las mismas queries que ya
/// alimentaban el export CSV, pero produce un .xlsx con formato (encabezado
/// destacado, columnas anchas según el contenido, montos como números con
/// separador de miles, así las sumas funcionan en Excel/Sheets).
///
/// [filas] es una lista de filas; cada celda puede ser `num` (→ celda numérica
/// con formato) o `String` (→ texto) o `null` (→ celda vacía). Los `int` se
/// muestran como enteros (conteos) y los `double` con 2 decimales (montos).
/// Devuelve la ruta donde se guardó, o `null` si el usuario canceló.
Future<String?> descargarExcel({
  required String fileName,
  required String hojaNombre,
  required List<String> headers,
  required List<List<Object?>> filas,
}) async {
  final excel = Excel.createExcel();
  // createExcel arranca con una hoja default ('Sheet1'); la renombramos a algo
  // descriptivo en vez de crear otra y tener que borrar la default.
  final defaultName = excel.getDefaultSheet();
  if (defaultName != null && defaultName != hojaNombre) {
    excel.rename(defaultName, hojaNombre);
  }
  final sheet = excel[hojaNombre];

  // Estilos reutilizables.
  final headerStyle = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.blueGrey800,
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  // Enteros (conteos): separador de miles, sin decimales, a la derecha.
  final intStyle = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0'),
  );
  // Montos (double): separador de miles + 2 decimales, a la derecha.
  final moneyStyle = CellStyle(
    horizontalAlign: HorizontalAlign.Right,
    numberFormat: NumFormat.custom(formatCode: '#,##0.00'),
  );

  // Fila 0: encabezado.
  sheet.appendRow(headers.map<CellValue?>((h) => TextCellValue(h)).toList());
  for (var c = 0; c < headers.length; c++) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
        .cellStyle = headerStyle;
  }

  // Filas de datos: aplicamos formato numérico a las celdas num según su tipo.
  for (var r = 0; r < filas.length; r++) {
    final fila = filas[r];
    sheet.appendRow(fila.map(_celda).toList());
    final rowIndex = r + 1; // +1 porque la fila 0 es el encabezado
    for (var c = 0; c < fila.length; c++) {
      final v = fila[c];
      if (v is int) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex))
            .cellStyle = intStyle;
      } else if (v is num) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIndex))
            .cellStyle = moneyStyle;
      }
    }
  }

  // Ancho de columnas según el contenido más largo (encabezado o celda),
  // acotado a un rango razonable para que no quede ni cortado ni gigante.
  for (var c = 0; c < headers.length; c++) {
    var maxLen = headers[c].length;
    for (final fila in filas) {
      if (c < fila.length) {
        final s = fila[c]?.toString() ?? '';
        if (s.length > maxLen) maxLen = s.length;
      }
    }
    sheet.setColumnWidth(c, (maxLen + 3).clamp(12, 50).toDouble());
  }

  final saved = excel.save();
  if (saved == null) {
    throw Exception('No se pudo generar el archivo Excel');
  }

  return guardarArchivo(fileName: fileName, bytes: saved, extension: 'xlsx');
}

/// Mapea un valor crudo de una fila a la celda tipada de Excel. Los números
/// quedan como números (sumables en Excel); el resto, como texto.
CellValue? _celda(Object? v) {
  if (v == null) return null;
  if (v is int) return IntCellValue(v);
  if (v is double) return DoubleCellValue(v);
  if (v is num) return DoubleCellValue(v.toDouble());
  return TextCellValue(v.toString());
}
