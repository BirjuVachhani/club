/// Shared `yaml_edit` helpers used by every code path that mutates a
/// pubspec.yaml in this CLI.
library;

import 'package:yaml_edit/yaml_edit.dart';

/// Ensure that the map at [path] exists so subsequent `editor.update(path +
/// [childKey], ...)` calls can attach a child key.
///
/// `yaml_edit` requires the parent node to be a map before child writes —
/// pubspec.yaml may legitimately be missing `dev_dependencies:`,
/// `dependency_overrides:`, etc., or have them present as a `null`-valued
/// scalar (`dev_dependencies:` followed by no body parses as null). Both
/// shapes need to be replaced with an empty map.
void ensureMapNode(YamlEditor editor, String key) =>
    ensureMapNodeAt(editor, [key]);

/// [ensureMapNode] for nested paths.
void ensureMapNodeAt(YamlEditor editor, List<Object> path) {
  try {
    final node = editor.parseAt(path);
    if (node.value != null) return;
    // Null-valued scalar at the path — fall through to overwrite as empty.
  } on ArgumentError {
    // Path does not exist yet — fall through to create.
  } on StateError {
    // Path traverses into a non-map node — overwrite as empty map.
  }
  editor.update(path, <String, Object?>{});
}
