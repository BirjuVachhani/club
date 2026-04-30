import 'dart:convert';
import 'dart:io';

import 'package:club_server/src/scoring/scoring_worker.dart';
import 'package:test/test.dart';

/// IPC round-trip smoke tests.
///
/// Can't exercise the real scoring subprocess without a Dart SDK + pana
/// dependencies in the tempdir — too heavy for a unit test. Instead we
/// exercise the *protocol*: parent writes a job JSON on stdin, child
/// decodes it and writes a result JSON on stdout, parent decodes.
///
/// A tiny inline fake-child script reads/echoes/exits, proving the
/// plumbing the real ScoringService uses.
void main() {
  group('ScoringJob / ScoringResult JSON', () {
    test('round-trips every field', () {
      final job = ScoringJob(
        packageName: 'foo',
        version: '1.2.3',
        tarballPath: '/tmp/foo.tar.gz',
        dartSdkPath: '/opt/dart',
        flutterSdkPath: '/opt/flutter',
        pubCacheDir: '/tmp/pub-cache',
        tempBaseDir: '/tmp',
        licenseDataDir: '/opt/spdx',
        dartdocOutputDir: '/data/dartdoc/foo',
      );
      final rt = ScoringJob.fromJson(
        jsonDecode(jsonEncode(job.toJson())) as Map<String, dynamic>,
      );
      expect(rt.packageName, job.packageName);
      expect(rt.version, job.version);
      expect(rt.tarballPath, job.tarballPath);
      expect(rt.dartSdkPath, job.dartSdkPath);
      expect(rt.flutterSdkPath, job.flutterSdkPath);
      expect(rt.pubCacheDir, job.pubCacheDir);
      expect(rt.tempBaseDir, job.tempBaseDir);
      expect(rt.licenseDataDir, job.licenseDataDir);
      expect(rt.dartdocOutputDir, job.dartdocOutputDir);
    });

    test('round-trips optional fields when null', () {
      final job = ScoringJob(
        packageName: 'foo',
        version: '1.0.0',
        tarballPath: '/x',
        dartSdkPath: '/dart',
        tempBaseDir: '/tmp',
      );
      final rt = ScoringJob.fromJson(
        jsonDecode(jsonEncode(job.toJson())) as Map<String, dynamic>,
      );
      expect(rt.flutterSdkPath, isNull);
      expect(rt.pubCacheDir, isNull);
      expect(rt.licenseDataDir, isNull);
      expect(rt.dartdocOutputDir, isNull);
    });

    test('ScoringResult round-trips with placeholder report JSON', () {
      final result = ScoringResult(
        packageName: 'foo',
        version: '1.0.0',
        success: true,
        grantedPoints: 120,
        maxPoints: 130,
        reportJson: '{"dropped":true}',
        panaVersion: '0.23.0',
        dartVersion: '3.9.0',
        flutterVersion: null,
        dartdocSuccess: true,
      );
      final rt = ScoringResult.fromJson(
        jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
      );
      expect(rt.success, isTrue);
      expect(rt.grantedPoints, 120);
      expect(rt.maxPoints, 130);
      expect(rt.reportJson, '{"dropped":true}');
      expect(rt.dartdocSuccess, isTrue);
      expect(rt.flutterVersion, isNull);
    });
  });

  group('subprocess IPC plumbing', () {
    late Directory tempDir;
    late File fakeChild;

    setUpAll(() async {
      // Minimal child script matching the real scoring_subprocess.dart
      // protocol: reads ScoringJob JSON from argv[0], writes ScoringResult
      // JSON to argv[1], exits 0. Also prints junk to stdout to prove the
      // parent ignores stdout and relies only on the result file.
      tempDir = await Directory.systemTemp.createTemp('scoring-ipc-test');
      fakeChild = File('${tempDir.path}/fake_child.dart');
      await fakeChild.writeAsString(r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final jobText = await File(args[0]).readAsString();
  final job = jsonDecode(jobText) as Map<String, dynamic>;

  // Simulate pana's build-hook chatter on stdout; parent should ignore it.
  stdout.writeln('Running build hooks...');
  // Structured progress on stderr — parent routes this to the logger.
  stderr.writeln('fake_child: processing ${job["packageName"]}');

  final result = {
    'packageName': job['packageName'],
    'version': job['version'],
    'success': true,
    'grantedPoints': 42,
    'maxPoints': 100,
    'reportJson': '{"fake":true}',
    'panaVersion': 'fake',
    'dartVersion': 'fake',
    'flutterVersion': null,
    'errorMessage': null,
    'dartdocSuccess': false,
  };
  await File(args[1]).writeAsString(jsonEncode(result));
  exit(0);
}
''');
    });

    tearDownAll(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test(
      'parent → child → parent round-trip via file paths',
      () async {
        final jobPath = '${tempDir.path}/test-job.json';
        final resultPath = '${tempDir.path}/test-result.json';
        final job = ScoringJob(
          packageName: 'smoketest',
          version: '0.0.1',
          tarballPath: '/dev/null',
          dartSdkPath: '/dev/null',
          tempBaseDir: tempDir.path,
        );
        await File(jobPath).writeAsString(jsonEncode(job.toJson()));

        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', fakeChild.path, jobPath, resultPath],
        );

        final stderrLines = <String>[];
        final stderrDone = process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(stderrLines.add)
            .asFuture<void>();
        // Drain stdout (the child deliberately pollutes it).
        final stdoutDone = process.stdout.drain<void>();

        final exitCode = await process.exitCode;
        await stderrDone;
        await stdoutDone;

        expect(exitCode, 0);
        expect(
          stderrLines,
          contains('fake_child: processing smoketest'),
        );
        final result = ScoringResult.fromJson(
          jsonDecode(await File(resultPath).readAsString())
              as Map<String, dynamic>,
        );
        expect(result.success, isTrue);
        expect(result.packageName, 'smoketest');
        expect(result.grantedPoints, 42);
        expect(result.reportJson, '{"fake":true}');
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}
