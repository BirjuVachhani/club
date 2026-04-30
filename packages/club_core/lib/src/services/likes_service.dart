import '../exceptions.dart';
import '../models/package.dart';
import '../repositories/metadata_store.dart';

/// Handles package favorites / likes.
class LikesService {
  LikesService({required MetadataStore store}) : _store = store;

  final MetadataStore _store;

  Future<bool> isLiked(String userId, String packageName) =>
      _store.hasLike(userId, packageName);

  Future<void> like(String userId, String packageName) async {
    final pkg = await _store.lookupPackage(packageName);
    if (pkg == null) throw NotFoundException.package(packageName);

    final already = await _store.hasLike(userId, packageName);
    if (already) return;

    await _store.likePackage(userId, packageName);
    await _store.updatePackage(
      packageName,
      PackageCompanion(
        name: packageName,
        likesCount: pkg.likesCount + 1,
      ),
    );
  }

  Future<void> unlike(String userId, String packageName) async {
    final pkg = await _store.lookupPackage(packageName);
    if (pkg == null) throw NotFoundException.package(packageName);

    final liked = await _store.hasLike(userId, packageName);
    if (!liked) return;

    await _store.unlikePackage(userId, packageName);
    final newCount = (pkg.likesCount - 1).clamp(0, pkg.likesCount);
    await _store.updatePackage(
      packageName,
      PackageCompanion(
        name: packageName,
        likesCount: newCount,
      ),
    );
  }

  Future<int> getLikeCount(String packageName) => _store.likeCount(packageName);

  Future<List<String>> getLikedPackages(String userId) =>
      _store.likedPackages(userId);
}
