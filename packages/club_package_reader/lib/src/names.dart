// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// club_package_reader modifications:
//   - Dropped `knownMixedCasePackages`, `knownGoodLowerCasePackages`, and
//     `blockedLowerCasePackages`. Those lists exist to grandfather legacy
//     pub.dev packages; a fresh private registry has no such history.
//   - `validateNewPackageName` (the caller of those tables) is gated out via
//     `ReaderPolicy.checkMixedCasePackageNames` instead of being called.

final RegExp identifierExpr = RegExp(r'^[a-zA-Z0-9_]+$');
final RegExp startsWithLetterOrUnderscore = RegExp(r'^[a-zA-Z_]');
const reservedWords = <String>{
  'abstract',
  'as',
  'assert',
  // 'async', // reserved, but allowed because package:async already exists.
  'augment',
  'await',
  // 'base', // reserved, but allowed because package:base already exists.
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'inline',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'type',
  'typedef',
  'var',
  'void',
  // 'when', // reserved, but allowed because package:when already exists.
  'while',
  'with',
  'yield',
};

final invalidHostNames = const <String>[
  '-',
  '--',
  '---',
  '..',
  '...',
  'example.com',
  'example.org',
  'example.net',
  'google.com',
  'www.example.com',
  'www.example.org',
  'www.example.net',
  'www.google.com',
  'none',
];
