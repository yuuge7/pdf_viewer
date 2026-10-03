import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/sheet/formula.dart';
import 'package:pdf_viewer/services/sheet/number_format.dart';
import 'package:pdf_viewer/services/sheet/sheet_styles.dart';
import 'package:pdf_viewer/services/sheet/workbook.dart';
import 'package:pdf_viewer/services/sheet/xlsx_file.dart';

/// Cells by name, on one sheet or several ("Other!A1").
class Cells implements FormulaContext {
  final Map<String, Object?> values;
  Cells(this.values);

  @override
  Object? cellValue(String? sheet, int row, int col) =>
      values['${sheet == null ? '' : '$sheet!'}${cellName(row, col)}'];

  @override
  (int, int) extent(String? sheet) => (10, 5);
}

Object? eval(String formula, [Map<String, Object?> cells = const {}]) =>
    Formula.evaluate(formula, Cells(cells));

const String _main =
    'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const String _rel =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const String _pkg = 'http://schemas.openxmlformats.org/package/2006';

/// A workbook the way Excel writes one: shared strings, a shared formula,
/// a merge, frozen panes, a theme colour, a list validation, and parts this
/// editor knows nothing about.
Uint8List excelLikeWorkbook() {
  final Archive archive = Archive();
  void add(String name, String content) =>
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(content)));
  add(
    '[Content_Types].xml',
    '<Types xmlns="$_pkg/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>'
        '</Types>',
  );
  add(
    '_rels/.rels',
    '<Relationships xmlns="$_pkg/relationships">'
        '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
  );
  add(
    'xl/workbook.xml',
    '<workbook xmlns="$_main" xmlns:r="$_rel"><sheets>'
        '<sheet name="Sales" sheetId="1" r:id="rId1"/>'
        '<sheet name="Lists" sheetId="2" r:id="rId2"/>'
        '</sheets><definedNames><definedName name="Rate">Sales!\$A\$1</definedName></definedNames></workbook>',
  );
  add(
    'xl/_rels/workbook.xml.rels',
    '<Relationships xmlns="$_pkg/relationships">'
        '<Relationship Id="rId1" Type="$_rel/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="$_rel/worksheet" Target="worksheets/sheet2.xml"/>'
        '<Relationship Id="rId3" Type="$_rel/styles" Target="styles.xml"/>'
        '<Relationship Id="rId4" Type="$_rel/sharedStrings" Target="sharedStrings.xml"/>'
        '<Relationship Id="rId5" Type="$_rel/calcChain" Target="calcChain.xml"/>'
        '</Relationships>',
  );
  add(
    'xl/sharedStrings.xml',
    '<sst xmlns="$_main"><si><t>Item</t></si><si><r><t>Wid</t></r><r><rPr><b/></rPr><t>gets</t></r></si>'
        '<si><t>Total</t></si></sst>',
  );
  add(
    'xl/styles.xml',
    '<styleSheet xmlns="$_main">'
        '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00 &quot;lei&quot;"/></numFmts>'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="14"/><color theme="4" tint="-0.25"/><name val="Calibri"/></font></fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></patternFill></fill></fills>'
        '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>'
        '<border><left/><right/><top/><bottom style="medium"><color rgb="FF0000FF"/></bottom><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1"><alignment horizontal="center"/></xf>'
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
        '</styleSheet>',
  );
  add('xl/calcChain.xml', '<calcChain xmlns="$_main"><c r="C2"/><c r="C3"/></calcChain>');
  add('xl/media/logo.bin', 'not really a picture');
  add(
    'xl/worksheets/sheet1.xml',
    '<worksheet xmlns="$_main"><dimension ref="A1:C4"/>'
        '<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="1" topLeftCell="B2" state="frozen"/></sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        '<cols><col min="1" max="1" width="20" customWidth="1"/></cols>'
        '<sheetData>'
        '<row r="1" ht="24" customHeight="1"><c r="A1" s="1" t="s"><v>0</v></c><c r="B1" s="1"/><c r="C1" s="1" t="s"><v>2</v></c></row>'
        '<row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>4</v></c><c r="C2" s="2"><f t="shared" ref="C2:C3" si="0">B2*2.5</f><v>10</v></c></row>'
        '<row r="3"><c r="A3" t="inlineStr"><is><t>Gadgets</t></is></c><c r="B3"><v>6</v></c><c r="C3" s="2"><f t="shared" si="0"/><v>15</v></c></row>'
        '<row r="4"><c r="B4"><f>SUM(B2:B3)</f><v>10</v></c><c r="C4"><f>FANCYNEWFUNCTION(C2:C3)</f><v>25</v></c></row>'
        '</sheetData>'
        '<mergeCells count="1"><mergeCell ref="A1:B1"/></mergeCells>'
        '<dataValidations count="2">'
        '<dataValidation type="list" sqref="A2:A3"><formula1>"Widgets,Gadgets,Gizmos"</formula1></dataValidation>'
        '<dataValidation type="list" sqref="B6"><formula1>Lists!\$A\$1:\$A\$2</formula1></dataValidation>'
        '</dataValidations>'
        '</worksheet>',
  );
  add(
    'xl/worksheets/sheet2.xml',
    '<worksheet xmlns="$_main"><sheetData>'
        '<row r="1"><c r="A1" t="inlineStr"><is><t>North</t></is></c></row>'
        '<row r="2"><c r="A2" t="inlineStr"><is><t>South</t></is></c></row>'
        '</sheetData></worksheet>',
  );
  return ZipEncoder().encodeBytes(archive);
}

String partOf(Uint8List bytes, String name) => utf8.decode(
  ZipDecoder().decodeBytes(bytes).findFile(name)!.readBytes()!,
);

void main() {
  group('formulas', () {
    test('arithmetic follows spreadsheet precedence', () {
      expect(eval('1+2*3'), 7);
      expect(eval('(1+2)*3'), 9);
      expect(eval('2^3^2'), 64);
      expect(eval('-2^2'), 4);
      expect(eval('50%*8'), 4);
      expect(eval('10/4'), 2.5);
      expect(eval('1/0'), SheetError.div0);
    });

    test('compares and joins', () {
      expect(eval('3>2'), true);
      expect(eval('"apple"="APPLE"'), true);
      expect(eval('"a"&1+1&"b"'), 'a2b');
      expect(eval('"say ""hi"""'), 'say "hi"');
      expect(eval('1<>1'), false);
    });

    test('reads cells and ranges, on this sheet and others', () {
      final Map<String, Object?> cells = {
        'A1': 2.0,
        'A2': 3.0,
        'A3': 'text',
        'B1': 10.0,
        'Other!A1': 100.0,
        'My Sheet!B2': 5.0,
      };
      expect(eval('A1+A2', cells), 5);
      expect(eval('SUM(A1:A3)', cells), 5);
      expect(eval(r'SUM($A$1:B2)', cells), 15);
      expect(eval('Other!A1/A1', cells), 50);
      expect(eval("'My Sheet'!B2*2", cells), 10);
      expect(eval('AVERAGE(A1:A2)', cells), 2.5);
      expect(eval('COUNT(A1:A3)', cells), 2);
      expect(eval('COUNTA(A1:A3)', cells), 3);
      expect(eval('A9+1', cells), 1);
    });

    test('the functions people type', () {
      final Map<String, Object?> cells = {
        'A1': 'pear',
        'B1': 4.0,
        'A2': 'apple',
        'B2': 6.0,
        'A3': 'pear',
        'B3': 10.0,
      };
      expect(eval('IF(B1>3,"big","small")', cells), 'big');
      expect(eval('IF(B1>30,"big")', cells), false);
      expect(eval('IFERROR(1/0,"none")'), 'none');
      expect(eval('AND(TRUE,B1>1)', cells), true);
      expect(eval('OR(FALSE,B1>100)', cells), false);
      expect(eval('ROUND(2.675,2)'), 2.68);
      expect(eval('ROUND(-1.5,0)'), -2);
      expect(eval('ROUNDDOWN(2.99,0)'), 2);
      expect(eval('MOD(-1,3)'), 2);
      expect(eval('SUMIF(A1:A3,"pear",B1:B3)', cells), 14);
      expect(eval('COUNTIF(B1:B3,">5")', cells), 2);
      expect(eval('VLOOKUP("apple",A1:B3,2,FALSE)', cells), 6);
      expect(eval('VLOOKUP("kiwi",A1:B3,2,FALSE)', cells), SheetError.na);
      expect(eval('UPPER(LEFT(A1,2))&LEN(A2)', cells), 'PE5');
      expect(eval('MID("spreadsheet",7,5)'), 'sheet');
      expect(eval('MAX(B1:B3)-MIN(B1:B3)', cells), 6);
      expect(eval('YEAR(DATE(2026,10,3))'), 2026);
    });

    test('errors travel, and what is not understood says so', () {
      expect(eval('1+#N/A'), SheetError.na);
      expect(eval('SUM(1,"x")'), SheetError.value);
      expect(() => eval('LAMBDA(x,x+1)(2)'), throwsA(isA<UnsupportedFormula>()));
      expect(() => eval('SomeName*2'), throwsA(isA<UnsupportedFormula>()));
      expect(Formula.isSupported('SUM(A1:A3)*2'), isTrue);
      expect(Formula.isSupported('XLOOKUP(A1,B:B,C:C)'), isFalse);
    });

    test('a formula copied elsewhere moves its relative references', () {
      expect(Formula.offset(r'A1+$B$2+C$3+$D4', 2, 1), r'B3+$B$2+D$3+$D6');
      expect(Formula.offset('SUM(A1:B2)&"A1"', 1, 0), 'SUM(A2:B3)&"A1"');
      expect(Formula.offset('A1', -1, 0), '#REF!');
    });

    test('inserting and deleting rows rewrites what pointed past them', () {
      String rows(String f, int index, int count) => Formula.shift(
        f,
        sheet: 'S',
        ownSheet: 'S',
        index: index,
        count: count,
        columns: false,
      );
      expect(rows('A1+A5', 2, 1), 'A1+A6');
      expect(rows(r'SUM($A$2:A9)', 4, 2), r'SUM($A$2:A11)');
      expect(rows('A5', 4, -1), '#REF!');
      expect(rows('A6', 4, -1), 'A5');
      expect(rows('SUM(A2:A9)', 4, -2), 'SUM(A2:A7)');
      expect(rows('SUM(A5:A6)', 4, -2), 'SUM(#REF!)');
      expect(rows('Other!A9', 2, 1), 'Other!A9');
      expect(
        Formula.shift(
          'S!C1+C1',
          sheet: 'S',
          ownSheet: 'T',
          index: 1,
          count: 1,
          columns: true,
        ),
        'S!D1+C1',
      );
    });
  });

  group('number formats', () {
    test('decimals, grouping and percentages', () {
      expect(NumberFormat.format(1234.5, '0.00'), '1234.50');
      expect(NumberFormat.format(1234567.891, '#,##0.00'), '1,234,567.89');
      expect(NumberFormat.format(0.256, '0%'), '26%');
      expect(NumberFormat.format(0.5, '#.##'), '.5');
      expect(NumberFormat.format(7, '000'), '007');
      expect(NumberFormat.format(12.0, 'General'), '12');
      expect(NumberFormat.format(0.1 + 0.2, 'General'), '0.3');
      expect(NumberFormat.format(1234567, '0.00E+00'), '1.23E+06');
    });

    test('text around the number, and a section for negatives', () {
      expect(NumberFormat.format(12.5, '#,##0.00 "lei"'), '12.50 lei');
      expect(NumberFormat.format(-12.5, '#,##0.00;(#,##0.00)'), '(12.50)');
      expect(NumberFormat.format(3, r'[$€-407] #,##0.00'), '€ 3.00');
      expect(NumberFormat.format(-3, '0.0;[Red]-0.0'), '-3.0');
    });

    test('dates and times', () {
      // 3 October 2026, 14:30.
      const double serial = 46298 + 14.5 / 24;
      expect(NumberFormat.format(serial, 'yyyy-mm-dd'), '2026-10-03');
      expect(NumberFormat.format(serial, 'd mmm yyyy'), '3 Oct 2026');
      expect(NumberFormat.format(serial, 'dd/mm/yyyy hh:mm'), '03/10/2026 14:30');
      expect(NumberFormat.format(serial, 'h:mm AM/PM'), '2:30 PM');
      expect(NumberFormat.format(serial, 'dddd'), 'Saturday');
      expect(NumberFormat.isDate('dd/mm/yyyy'), isTrue);
      expect(NumberFormat.isDate('0.00'), isFalse);
      expect(
        NumberFormat.serialOf(DateTime(2026, 10, 3)),
        46298,
      );
    });
  });

  group('reading a workbook', () {
    late Workbook book;
    setUp(() => book = XlsxFile.read(excelLikeWorkbook()));

    test('finds the sheets, cells and shared strings', () {
      expect(book.sheets.map((s) => s.name), ['Sales', 'Lists']);
      final Sheet sales = book.sheets[0];
      expect(sales.cell(0, 0)!.value, 'Item');
      expect(sales.cell(1, 0)!.value, 'Widgets');
      expect(sales.cell(2, 0)!.value, 'Gadgets');
      expect(sales.cell(1, 1)!.value, 4);
      expect(sales.usedRows, 4);
      expect(sales.usedCols, 3);
    });

    test('opens a shared formula out over its range', () {
      final Sheet sales = book.sheets[0];
      expect(sales.cell(1, 2)!.formula, 'B2*2.5');
      expect(sales.cell(2, 2)!.formula, 'B3*2.5');
      expect(book.valueAt(0, 2, 2), 15);
    });

    test('layout: sizes, merges, frozen panes, lists', () {
      final Sheet sales = book.sheets[0];
      expect(sales.colWidths[0], 20);
      expect(sales.rowHeights[0], 24);
      expect(sales.frozenRows, 1);
      expect(sales.frozenCols, 1);
      expect(sales.merges.single.name, 'A1:B1');
      expect(sales.mergeAt(0, 1), isNotNull);
      expect(
        book.optionsFor(0, sales.validationAt(1, 0)!),
        ['Widgets', 'Gadgets', 'Gizmos'],
      );
      expect(book.optionsFor(0, sales.validationAt(5, 1)!), ['North', 'South']);
      expect(sales.validationAt(9, 9), isNull);
    });

    test('formats: fonts, fills, borders, theme colours, number formats', () {
      final CellStyle header = book.styles.at(book.sheets[0].cell(0, 0)!.style);
      expect(header.bold, isTrue);
      expect(header.fontSize, 14);
      expect(header.fill, 0xFFFFFF00);
      expect(header.hAlign, HAlign.center);
      expect(header.bottom!.width, 2);
      expect(header.bottom!.color, 0xFF0000FF);
      // Accent 1 of the default theme, a quarter darker.
      expect(header.color, isNot(0xFF4472C4));
      expect(header.color! & 0xFF, lessThan(0xC4));
      expect(book.display(0, 1, 2), '10.00 lei');
    });

    test('shows what it computes, and what it cannot as the file had it', () {
      expect(book.display(0, 3, 1), '10');
      expect(book.display(0, 3, 2), '25');
      expect(book.inputOf(0, 3, 1), '=SUM(B2:B3)');
      expect(book.inputOf(0, 1, 0), 'Widgets');
    });

    test('rejects what is not a workbook', () {
      expect(
        () => XlsxFile.read(Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException,
      );
    });
  });

  group('editing', () {
    late Workbook book;
    setUp(() => book = XlsxFile.read(excelLikeWorkbook()));

    test('typing is read the way a spreadsheet reads it', () {
      book.setInput(0, 6, 0, '42');
      book.setInput(0, 6, 1, '=A7*2');
      book.setInput(0, 6, 2, 'hello');
      book.setInput(0, 6, 3, '15%');
      book.setInput(0, 6, 4, "'007");
      book.setInput(0, 6, 5, 'true');
      final Sheet sales = book.sheets[0];
      expect(sales.cell(6, 0)!.value, 42);
      expect(book.valueAt(0, 6, 1), 84);
      expect(sales.cell(6, 2)!.value, 'hello');
      expect(sales.cell(6, 3)!.value, 0.15);
      expect(sales.cell(6, 4)!.value, '007');
      expect(sales.cell(6, 5)!.value, true);
      book.setInput(0, 6, 0, '');
      expect(sales.cell(6, 0), isNull);
      expect(book.valueAt(0, 6, 1), 0);
    });

    test('a change flows through the formulas that depend on it', () {
      expect(book.valueAt(0, 3, 1), 10);
      book.setInput(0, 1, 1, '40');
      expect(book.valueAt(0, 3, 1), 46);
      expect(book.valueAt(0, 1, 2), 100);
    });

    test('a formula that reads itself is an error, not a hang', () {
      book.setInput(0, 8, 0, '=A10');
      book.setInput(0, 9, 0, '=A9+1');
      expect(book.valueAt(0, 8, 0), isA<SheetError>());
    });

    test('inserting a row moves cells, merges, lists and formulas', () {
      book.shift(0, 1, 1, columns: false);
      final Sheet sales = book.sheets[0];
      expect(sales.cell(1, 0), isNull);
      expect(sales.cell(2, 0)!.value, 'Widgets');
      expect(sales.cell(2, 2)!.formula, 'B3*2.5');
      expect(sales.cell(4, 1)!.formula, 'SUM(B3:B4)');
      expect(sales.merges.single.name, 'A1:B1');
      expect(sales.validationAt(2, 0), isNotNull);
      expect(sales.validationAt(1, 0), isNull);
      expect(book.valueAt(0, 4, 1), 10);
    });

    test('deleting a column takes its cells and breaks what read them', () {
      book.shift(0, 1, -1, columns: true);
      final Sheet sales = book.sheets[0];
      expect(sales.cell(1, 1)!.formula, '#REF!*2.5');
      expect(sales.usedCols, 2);
      // The merge over A1:B1 is down to one cell, which is no merge.
      expect(sales.merges, isEmpty);
    });

    test('undo puts a sheet back as it was', () {
      final SheetSnapshot before = book.sheets[0].snapshot();
      book.shift(0, 0, 2, columns: false);
      book.setInput(0, 0, 0, 'changed');
      book.sheets[0].restore(before);
      book.invalidate();
      expect(book.sheets[0].cell(0, 0)!.value, 'Item');
      expect(book.sheets[0].cell(1, 2)!.formula, 'B2*2.5');
    });

    test('restyling adds a format and leaves the others alone', () {
      final int before = book.styles.count;
      book.applyStyle(
        0,
        const CellRange(1, 1, 2, 1),
        const StyleChange(bold: true, fill: 0xFF00FF00, numFmt: '0.00'),
      );
      expect(book.styles.count, before + 1);
      final CellStyle style = book.styles.at(book.sheets[0].cell(1, 1)!.style);
      expect(style.bold, isTrue);
      expect(style.fill, 0xFF00FF00);
      expect(book.display(0, 1, 1), '4.00');
      // Asking again reuses it.
      book.applyStyle(
        0,
        const CellRange(3, 1, 3, 1),
        const StyleChange(bold: true, fill: 0xFF00FF00, numFmt: '0.00'),
      );
      expect(book.styles.count, before + 1);
      expect(book.styles.at(1).bold, isTrue);
      expect(book.styles.at(1).fill, 0xFFFFFF00);
    });
  });

  group('writing', () {
    test('an untouched workbook reads back the same', () {
      final Workbook again = XlsxFile.read(
        XlsxFile.write(XlsxFile.read(excelLikeWorkbook())),
      );
      expect(again.sheets[0].cell(1, 0)!.value, 'Widgets');
      expect(again.sheets[0].cell(2, 2)!.formula, 'B3*2.5');
      expect(again.sheets[0].merges.single.name, 'A1:B1');
      expect(again.sheets[0].frozenRows, 1);
      expect(again.sheets[0].colWidths[0], 20);
      expect(again.sheets[0].rowHeights[0], 24);
      expect(again.display(0, 1, 2), '10.00 lei');
    });

    test('keeps the parts it does not understand', () {
      final Uint8List out = XlsxFile.write(XlsxFile.read(excelLikeWorkbook()));
      expect(partOf(out, 'xl/media/logo.bin'), 'not really a picture');
      expect(partOf(out, 'xl/workbook.xml'), contains('definedName'));
      // Untouched cells still point into the shared strings.
      expect(partOf(out, 'xl/worksheets/sheet1.xml'), contains('t="s"'));
      expect(partOf(out, 'xl/calcChain.xml'), contains('C2'));
    });

    test('edits, formats and new formulas survive a save', () {
      final Workbook book = XlsxFile.read(excelLikeWorkbook());
      book.setInput(0, 1, 1, '40');
      book.setInput(0, 5, 0, 'Café & <co>');
      book.setInput(0, 5, 1, '=B2+B3');
      book.applyStyle(
        0,
        const CellRange(5, 0, 5, 0),
        const StyleChange(italic: true, color: 0xFFFF0000, hAlign: HAlign.right),
      );
      book.sheets[0].colWidths[2] = 30;
      book.sheets[0].colsChanged = true;
      final Uint8List out = XlsxFile.write(book);

      final Workbook again = XlsxFile.read(out);
      expect(again.sheets[0].cell(1, 1)!.value, 40);
      expect(again.sheets[0].cell(5, 0)!.value, 'Café & <co>');
      expect(again.valueAt(0, 5, 1), 46);
      final CellStyle style = again.styles.at(again.sheets[0].cell(5, 0)!.style);
      expect(style.italic, isTrue);
      expect(style.color, 0xFFFF0000);
      expect(style.hAlign, HAlign.right);
      expect(again.sheets[0].colWidths[2], 30);
      expect(again.sheets[0].colWidths[0], 20);

      // The result of the formula it could work out is in the file; the one
      // it could not is left for Excel, which is told to recalculate.
      final String sheet = partOf(out, 'xl/worksheets/sheet1.xml');
      expect(sheet, contains('<f>B2+B3</f><v>46</v>'));
      expect(sheet, contains('<f>FANCYNEWFUNCTION(C2:C3)</f></c>'));
      expect(partOf(out, 'xl/workbook.xml'), contains('fullCalcOnLoad="1"'));
      // A stale calculation chain makes Excel call the file damaged.
      final Archive archive = ZipDecoder().decodeBytes(out);
      expect(archive.findFile('xl/calcChain.xml'), isNull);
      expect(partOf(out, '[Content_Types].xml'), isNot(contains('calcChain')));
      expect(
        partOf(out, 'xl/_rels/workbook.xml.rels'),
        isNot(contains('calcChain')),
      );
    });

    test('rows inserted before a save land in the right place', () {
      final Workbook book = XlsxFile.read(excelLikeWorkbook());
      book.shift(0, 1, 2, columns: false);
      final Workbook again = XlsxFile.read(XlsxFile.write(book));
      expect(again.sheets[0].cell(3, 0)!.value, 'Widgets');
      expect(again.sheets[0].cell(5, 1)!.formula, 'SUM(B4:B5)');
      expect(again.sheets[0].validationAt(3, 0), isNotNull);
      expect(again.sheets[0].rowHeights[0], 24);
    });

    test('a blank workbook and a CSV both come out as real workbooks', () {
      final Workbook blank = XlsxFile.blank();
      blank.setInput(0, 0, 0, 'Name');
      blank.setInput(0, 1, 0, '=1+1');
      final Workbook again = XlsxFile.read(XlsxFile.write(blank));
      expect(again.sheets.single.name, 'Sheet1');
      expect(again.sheets[0].cell(0, 0)!.value, 'Name');
      expect(again.valueAt(0, 1, 0), 2);

      final Workbook csv = XlsxFile.fromCsv(
        'name;qty;note\r\n"Smith; J";3;"said ""hi"""\r\nLee;4.5;\r\n',
      );
      expect(csv.sheets[0].cell(1, 0)!.value, 'Smith; J');
      expect(csv.sheets[0].cell(1, 1)!.value, 3);
      expect(csv.sheets[0].cell(1, 2)!.value, 'said "hi"');
      expect(csv.sheets[0].cell(2, 1)!.value, 4.5);
      expect(csv.sheets[0].usedRows, 3);
      expect(csv.edited, isFalse);
    });
  });
}
