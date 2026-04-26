import 'dart:io';

import 'package:club_server/src/dartdoc/sanitizer.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeDartdocTree', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('club-sanitizer-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> write(String relativePath, String content) async {
      final file = File('${tempDir.path}/$relativePath');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return file;
    }

    test('strips inline <script> tags but keeps same-origin src references',
        () async {
      final file = await write('index.html', '''
<!doctype html>
<html>
<body>
  <script>alert(document.cookie);</script>
  <script src="static-assets/docs.dart.js"></script>
  <p>hello</p>
</body>
</html>
''');

      final stats = await sanitizeDartdocTree(tempDir);

      final after = await file.readAsString();
      expect(after, isNot(contains('alert(document.cookie)')));
      expect(after, contains('static-assets/docs.dart.js'));
      expect(stats.inlineScriptsRemoved, 1);
      expect(stats.htmlFilesRewritten, 1);
    });

    test('removes event-handler attributes', () async {
      final file = await write('page.html', '''
<!doctype html>
<html><body>
  <a href="#" onclick="alert(1)">click</a>
  <img src="x" onerror="alert(2)">
</body></html>
''');

      final stats = await sanitizeDartdocTree(tempDir);
      final after = await file.readAsString();

      expect(after, isNot(contains('onclick')));
      expect(after, isNot(contains('onerror')));
      expect(stats.eventHandlersRemoved, 2);
    });

    test('removes javascript: hrefs in HTML', () async {
      final file = await write('doc.html', '''
<!doctype html>
<html><body>
  <a href="javascript:alert(1)">x</a>
  <a href=" JaVa\tScRiPt:alert(2) ">y</a>
  <a href="/api/packages/foo">ok</a>
</body></html>
''');

      final stats = await sanitizeDartdocTree(tempDir);
      final after = await file.readAsString();

      expect(after, isNot(contains('javascript:')),
          reason: 'all javascript: schemes should be stripped');
      expect(after.toLowerCase(), isNot(contains('java\tscript')));
      expect(after, contains('/api/packages/foo'));
      expect(stats.javascriptUrisRemoved, 2);
    });

    test('removes inline <script> and event handlers from SVG', () async {
      final file = await write('diagram.svg', '''
<svg xmlns="http://www.w3.org/2000/svg">
  <script>alert(1)</script>
  <circle cx="50" cy="50" r="10" onmouseover="alert(2)" />
  <a xlink:href="javascript:alert(3)"><rect /></a>
</svg>
''');

      final stats = await sanitizeDartdocTree(tempDir);
      final after = await file.readAsString();

      expect(after, isNot(contains('alert(1)')));
      expect(after, isNot(contains('onmouseover')));
      expect(after, isNot(contains('javascript:')));
      expect(stats.inlineScriptsRemoved, greaterThanOrEqualTo(1));
      expect(stats.eventHandlersRemoved, greaterThanOrEqualTo(1));
      expect(stats.javascriptUrisRemoved, greaterThanOrEqualTo(1));
      expect(stats.svgFilesRewritten, 1);
    });

    test('removes <iframe>, <object>, <embed> entirely', () async {
      final file = await write('page.html', '''
<!doctype html>
<html><body>
  <iframe src="https://evil.example"></iframe>
  <object data="evil.swf"></object>
  <embed src="evil.swf">
  <p>keep me</p>
</body></html>
''');

      await sanitizeDartdocTree(tempDir);
      final after = await file.readAsString();

      expect(after, isNot(contains('<iframe')));
      expect(after, isNot(contains('<object')));
      expect(after, isNot(contains('<embed')));
      expect(after, contains('keep me'));
    });

    test('leaves non-HTML/SVG files untouched', () async {
      final js = await write('static-assets/docs.dart.js', 'console.log(1)');
      final css = await write('static-assets/styles.css', 'body{}');
      final png = File('${tempDir.path}/static-assets/logo.png');
      await png.parent.create(recursive: true);
      await png.writeAsBytes([0x89, 0x50, 0x4e, 0x47]);

      await sanitizeDartdocTree(tempDir);

      expect(await js.readAsString(), 'console.log(1)');
      expect(await css.readAsString(), 'body{}');
      expect(await png.readAsBytes(), [0x89, 0x50, 0x4e, 0x47]);
    });

    test('benign dartdoc page passes through without rewrite', () async {
      final file = await write('index.html', '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>docs</title>
  <link rel="stylesheet" href="static-assets/styles.css">
</head>
<body>
  <main><p>Welcome</p></main>
  <script src="static-assets/docs.dart.js"></script>
</body>
</html>
''');

      final stats = await sanitizeDartdocTree(tempDir);
      expect(stats.htmlFilesRewritten, 0);
      expect(stats.inlineScriptsRemoved, 0);
      expect(stats.eventHandlersRemoved, 0);
      expect(await file.exists(), isTrue);
    });
  });
}
