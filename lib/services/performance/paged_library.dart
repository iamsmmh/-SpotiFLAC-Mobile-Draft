/// Pagination + lazy windows (Phase 16).
///
/// Keeps a 100k-track library from being copied into a single list view.
library;

/// One page of [T].
class PageSlice<T> {
  const PageSlice({
    required this.items,
    required this.offset,
    required this.total,
    required this.limit,
  });

  final List<T> items;
  final int offset;
  final int total;
  final int limit;

  bool get hasMore => offset + items.length < total;

  int get nextOffset => offset + items.length;
}

/// Slices an in-memory catalog. Production binds this over SQLite LIMIT/OFFSET
/// instead of loading the whole table.
class PagedLibrary<T> {
  const PagedLibrary({this.pageSize = 200});

  final int pageSize;

  PageSlice<T> page(
    List<T> all, {
    int offset = 0,
    int? limit,
  }) {
    final size = limit ?? pageSize;
    final start = offset < 0 ? 0 : offset;
    if (start >= all.length || size <= 0) {
      return PageSlice<T>(
        items: <T>[],
        offset: start,
        total: all.length,
        limit: size < 0 ? 0 : size,
      );
    }
    final end = start + size > all.length ? all.length : start + size;
    return PageSlice<T>(
      items: List<T>.unmodifiable(all.sublist(start, end)),
      offset: start,
      total: all.length,
      limit: size,
    );
  }
}
