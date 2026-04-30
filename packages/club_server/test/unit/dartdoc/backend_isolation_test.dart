import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:club_indexed_blob/club_indexed_blob.dart';
import 'package:club_server/src/dartdoc/blob_handler.dart';
import 'package:club_server/src/dartdoc/cache.dart';
import 'package:club_storage/club_storage.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// Regression guard: `DARTDOC_BACKEND=blob` must never reach out to S3 or
/// GCS on its own. It always uses the `BlobStore` instance the operator
/// configured via `BLOB_BACKEND`. The happiest path to verify this is an
/// end-to-end write + read against `FilesystemBlobStore` on a local temp
/// directory, with zero network-capable dependencies in the picture.
void main() {
  group('blob dartdoc + filesystem BLOB_BACKEND', () {
    late Directory tmp;
    late FilesystemBlobStore blobStore;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('club-dartdoc-fs-');
      blobStore = FilesystemBlobStore(rootPath: tmp.path);
      await blobStore.open();
    });

    tearDown(() async {
      await blobStore.close();
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test(
      'upload via putAsset + serve via blob handler works end-to-end on '
      'a local filesystem blob store',
      () async {
        // Build an indexed blob the same way the scoring worker does
        // via `BlobIndexPair.folderToIndexedBlob`: each file gzip-
        // encoded individually before being added to the concatenated
        // blob. The serve-side handler trusts this invariant.
        final pair = await BlobIndexPair.build('fs-blob-1', (addFile) async {
          await addFile(
            'index.html',
            Stream.value(gzip.encode(utf8.encode('<h1>local</h1>'))),
          );
        });

        // Persist exactly where the scoring service puts blob-mode docs.
        await blobStore.putAsset(
          'demo_pkg',
          'dartdoc/latest/blob',
          Stream.value(pair.blob),
        );
        await blobStore.putAsset(
          'demo_pkg',
          'dartdoc/latest/index.json',
          Stream.value(pair.index.asBytes()),
        );

        // Confirm the on-disk shape: pure filesystem, no remote call.
        expect(
          await File(
            '${tmp.path}/demo_pkg/dartdoc/latest/blob',
          ).exists(),
          isTrue,
          reason: 'blob must land on local disk when BLOB_BACKEND=filesystem',
        );
        expect(
          await File(
            '${tmp.path}/demo_pkg/dartdoc/latest/index.json',
          ).exists(),
          isTrue,
        );

        // Now serve it through the blob handler — same code path as a
        // real DARTDOC_BACKEND=blob deployment.
        final handler = makeBlobDartdocHandler(
          blobStore: blobStore,
          cache: InMemoryDartdocCache(maxMemoryBytes: 1 << 20),
        );
        final resp = await handler(
          shelf.Request(
            'GET',
            Uri.parse('http://test/documentation/demo_pkg/latest/'),
          ),
          'demo_pkg',
          'latest',
          '/',
        );
        expect(resp.statusCode, 200);
        // Body is raw (no gzip per-file in this test — indexed-blob
        // accepts any bytes, gzip is just the caller's choice).
        final body = await resp.read().fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        expect(utf8.decode(body), '<h1>local</h1>');
      },
    );
  });
}
