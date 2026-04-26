/// Core domain models, interfaces, services, and validation for club.
library;

// Models
export 'src/models/user.dart';
export 'src/models/user_role.dart';
export 'src/models/user_invite.dart';
export 'src/models/api_token.dart';
export 'src/models/package.dart';
export 'src/models/package_version.dart';
export 'src/models/package_screenshot.dart';
export 'src/models/publisher.dart';
export 'src/models/publisher_member.dart';
export 'src/models/publisher_verification.dart';
export 'src/models/upload_session.dart';
export 'src/models/audit_log.dart';
export 'src/models/search.dart';
export 'src/models/package_score.dart';
export 'src/models/dartdoc_status.dart';
export 'src/models/sdk_install.dart';

// API DTOs (pub spec v2 wire format)
export 'src/models/api/package_data.dart';
export 'src/models/api/version_info.dart';
export 'src/models/api/upload_info.dart';
export 'src/models/api/success_message.dart';
export 'src/models/api/pkg_options.dart';
export 'src/models/api/version_options.dart';
export 'src/models/api/version_score.dart';
export 'src/models/api/package_publisher_info.dart';
export 'src/models/api/package_download_history.dart';

// Repository interfaces
export 'src/repositories/metadata_store.dart';
export 'src/repositories/blob_store.dart';
export 'src/repositories/search_index.dart';
export 'src/repositories/settings_store.dart';

// Services
export 'src/services/auth_service.dart';
export 'src/services/publish_service.dart';
export 'src/services/readme_asset_rewriter.dart';
export 'src/services/package_service.dart';
export 'src/services/publisher_service.dart';
export 'src/services/likes_service.dart';
export 'src/services/download_service.dart';
export 'src/services/tag_derivation.dart';

// Authorization
export 'src/authz/permissions.dart';

// Validation
export 'src/validation/package_name_validator.dart';
export 'src/validation/version_validator.dart';

// Exceptions
export 'src/exceptions.dart';
