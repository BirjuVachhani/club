/// Maps [UserRole] values to the token scope list a freshly-issued
/// login/CLI token should carry. Kept in one place so the web login and
/// the CLI OAuth flow can't drift apart.
library;

import 'package:club_core/club_core.dart';

List<String> scopesForRole(UserRole role) {
  switch (role) {
    case UserRole.owner:
    case UserRole.admin:
      return const [TokenScope.read, TokenScope.write, TokenScope.admin];
    case UserRole.member:
      return const [TokenScope.read, TokenScope.write];
    case UserRole.viewer:
      return const [TokenScope.read];
  }
}
