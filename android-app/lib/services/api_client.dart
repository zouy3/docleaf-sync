import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/author_profile.dart';
import '../models/backend_resource_url.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_ideas.dart';
import '../models/channel_tab.dart';
import '../models/chapter_summary.dart';
import '../models/comment_reply.dart';
import '../models/media_item.dart';
import '../models/media_id.dart';
import '../models/rank.dart';
import '../models/search_discovery.dart';
import 'app_log.dart';
import 'backend_service.dart';
import 'backend_transport.dart';
import 'chapter_text_formatter.dart';
import 'request_gate.dart';

/// A parsed homepage page. Keeping the cursor next to the parsed cards lets
/// callers update the feed atomically after checking that the request is
/// still current.
class HomepagePage {
  final List<MediaItem> items;
  final int? nextOffset;
  final String? sessionId;

  const HomepagePage({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
  });
}

/// API client talking to the local Rust core.
///
/// Uses the same `/api/*` bridge the web UI uses, so responses are already
/// normalized for the frontend (search tabs, chapterListWithVolume, etc.).
class ApiClient {
  ApiClient({
    http.Client? client,
    BackendTransport? transport,
    String? baseUrl,
    this._timeout = const Duration(seconds: 20),
  }) : _transport =
           transport ??
           (client != null || baseUrl != null
               ? HttpBackendTransport(
                   client: client,
                   baseUrl: baseUrl ?? BackendService.instance.baseUrl,
                 )
               : BackendService.instance.transport);

  static final ApiClient instance = ApiClient();

  /// Fixed read-only library resources; credentials stay in the POST body.
  Future<Map<String, dynamic>> fanqieLibraryResource({
    required String cookie,
    required String resource,
    String? deviceId,
    int offset = 0,
    int bookType = 0,
    List<String> bookIds = const [],
    String? folderId,
  }) async {
    final response = await _get(
      '$_base/api/v1/account/fanqie/library',
      method: 'POST',
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'cookie': cookie,
            'resource': resource,
            'device_id': ?deviceId,
            'offset': offset,
            'book_type': bookType,
            'book_ids': bookIds,
            'folder_id': ?folderId,
          }),
        ),
      ),
    );
    return _decodeAsync(response);
  }

  /// Preserve the detail payload for later interpretation instead of dropping
  /// fields through the display model. This endpoint needs no account cookie.
  Future<Map<String, dynamic>> fanqieBookMetadata(String bookId) async =>
      _decodeAsync(
        await _get(
          _url('/api/v1/books/${Uri.encodeComponent(bookId)}/detail', {}),
        ),
      );

  /// Read-only upstream operation. POST keeps the temporary login cookie out
  /// of URLs; the Rust adapter only permits the fixed upstream history GET.
  Future<Map<String, dynamic>> fanqieHistoryPage({
    required String cookie,
    required int offset,
    required int lastMinReadTimestampMs,
    required bool firstLoad,
    String? deviceId,
  }) async {
    final response = await _get(
      '$_base/api/v1/account/fanqie/history',
      method: 'POST',
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'cookie': cookie,
            'offset': offset,
            'last_min_read_timestamp_ms': lastMinReadTimestampMs,
            'is_first_load': firstLoad,
            'device_id': ?deviceId,
          }),
        ),
      ),
    );
    return _decodeAsync(response);
  }

  /// Per-instance gate: coalescing must not reach across test instances, and
  /// a restarted backend service gets a fresh flight table.
  final RequestGate _gate = RequestGate();

  /// Zone key carrying the [BackendRequest] a call belongs to.
  static final Object _requestZoneKey = Object();

  /// Binds every backend request started inside [body] to [request].
  ///
  /// The binding travels in the current Zone, so existing call sites keep their
  /// signatures while the request owner (a page, a feed loader) still controls
  /// cancellation: cancelling [request] aborts the in-flight Rust dispatch and
  /// the awaiting upstream call. This is the same mechanism
  /// `http.runWithClient` uses for test clients.
  Future<T> withCancellation<T>(
    BackendRequest request,
    Future<T> Function() body,
  ) {
    if (request.isCancelled) {
      return Future<T>.error(BackendRequestAborted('请求已取消'));
    }
    return runZoned(body, zoneValues: {_requestZoneKey: request});
  }

  /// Business calls go through the Rust core by default. Tests and the Web
  /// build inject an [http.Client]/base URL and get the loopback HTTP adapter,
  /// which shares the same Rust dispatcher.
  final BackendTransport _transport;

  /// Timeout applied to every backend request. The backend runs locally, so a
  /// healthy call returns in well under this; a hung child process or a stuck
  /// upstream request must not leave a page spinning forever.
  final Duration _timeout;

  // Encrypted comic chapters are downloaded and decrypted by the backend
  // before its JSON response is ready, so they need a separate finite limit.

  /// Base URL used to resolve backend-relative resources (`/src/...`). It is
  /// read from the transport so a backend restart cannot leave a stale port.
  String get _base => _transport.baseUrl;

  /// Base URL for resources an HTTP client will fetch.
  ///
  /// Unlike [_base] it carries the loopback capability in its path and ends in
  /// `/`, which is what lets [resolveBackendResource] re-anchor a root-relative
  /// `/src/...` under it. JSON API paths keep using [_base]: they travel over
  /// FFI, which never crosses the socket and so needs no capability.
  String get _resourceBase =>
      backendResourceBase(_transport.baseUrl, _transport.capability);

  /// Converts a backend-relative resource (`/src/foo.mp4`) into a URL the
  /// Flutter networking plugins can consume. JSON API paths stay untouched.
  String absoluteUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) {
      if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
          parsed.host.isEmpty) {
        return '';
      }
      return raw;
    }
    return resolveBackendResource(_resourceBase, raw);
  }

  /// Decodes and envelope-checks a response body on a background isolate so
  /// large JSON payloads never jank the UI thread.
  Future<Map<String, dynamic>> _decodeAsync(http.Response r) async {
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(() => _decodeEnvelope(statusCode, bodyBytes));
  }

  /// Sends a request to the local backend with a timeout.
  ///
  /// [method] exists for the few bridge endpoints that are POST-only upstream
  /// (comment replies); callers still pass their arguments as query parameters,
  /// which the backend reads from the URL either way.
  ///
  /// Every call passes through [RequestGate]: identical concurrent GETs share
  /// one upstream flight, and no more than sixteen talk to the core at once.
  Future<http.Response> _get(
    String url, {
    Duration? timeout,
    String method = 'GET',
    Uint8List? body,
  }) {
    // The transport owns the deadline: cancelling drops the in-flight Rust
    // dispatch (and therefore the upstream request, its retry backoff and any
    // pending write), so a late result can never be published.
    final request = Zone.current[_requestZoneKey];
    final effectiveTimeout = timeout ?? _timeout;
    // 日志只记方法与路由模板（数值/长十六进制段打码），不记 query、参数与请求体
    // —— 隐私纪律同 PlayerLoadSample：never URLs, keys or API bodies。
    final route = '$method ${_logRoute(url)}';
    final watch = Stopwatch()..start();
    final future = _gate.run(
      '$method $url ${effectiveTimeout.inMilliseconds}',
      request: request is BackendRequest ? request : null,
      share: method == 'GET' && body == null,
      send: () async {
        final response = await _transport.send(
          method,
          Uri.parse(url),
          body: body,
          timeout: effectiveTimeout,
          request: request is BackendRequest ? request : null,
        );
        return http.Response.bytes(
          response.body,
          response.statusCode,
          headers: response.contentType.isEmpty
              ? const {}
              : {'content-type': response.contentType},
        );
      },
    );
    // 只观察，不改变返回语义：错误照常传播给调用方。
    future.then(
      (response) {
        watch.stop();
        AppLog.d(
          'api',
          '$route ${response.statusCode} ${watch.elapsedMilliseconds}ms',
        );
      },
      onError: (Object error) {
        watch.stop();
        // Transport exceptions often include a complete URL, including query
        // parameters. Keep the failure observable without logging that detail.
        AppLog.w(
          'api',
          '$route 失败 ${watch.elapsedMilliseconds}ms (${error.runtimeType})',
        );
      },
    );
    return future;
  }

  static final RegExp _hexSegment = RegExp(r'^[0-9a-fA-F]+$');

  /// 从请求 URL 提取可安全记录的路由模板：丢弃 query/fragment，把纯数字段与
  /// 长十六进制段替换为 `{id}`，最多保留前 5 段。
  static String _logRoute(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '(invalid-url)';
    final masked = uri.pathSegments
        .where((s) => s.isNotEmpty)
        .map((s) {
          final numeric = int.tryParse(s) != null;
          final hexish = s.length >= 8 && _hexSegment.hasMatch(s);
          return numeric || hexish ? '{id}' : s;
        })
        .take(5);
    return '/${masked.join('/')}';
  }

  String _url(String path, Map<String, String> query) =>
      Uri.parse(_base).resolve(path).replace(queryParameters: query).toString();

  String _searchUrl(String query, int page) =>
      _url('/api/search', {'source': '番茄', 'query': query, 'page': '$page'});

  String _directoryUrl(String bookId, String tab) =>
      _url('/api/directory', {'source': '番茄', 'book_id': bookId, 'tab': tab});

  /// Search across content types.
  /// Returns normalized {tabs: [{title, data:[...]}], ...} structure.
  Future<Map<String, dynamic>> search(String query, {int page = 1}) async {
    final r = await _get(_searchUrl(query, page));
    return _decodeAsync(r);
  }

  /// Search with JSON decoding and model parsing combined into one isolate
  /// hop. This avoids decoding a large response in one isolate and then
  /// copying the resulting map into a second isolate for normalization.
  Future<List<SearchTab>> searchTabs(
    String query, {
    int page = 1,
    int? tabType,
    int? offset,
  }) async {
    final searchOffset = offset ?? (page > 1 ? page - 1 : 0) * 10;
    final url = tabType == null
        ? _searchUrl(query, page)
        : _url('/api/v1/search', {
            'query': query,
            'tab_type': '$tabType',
            'offset': '${searchOffset < 0 ? 0 : searchOffset}',
            'count': '10',
          });
    final r = await _get(url);
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(
      () => parseSearchTabs(
        _decodeEnvelope(statusCode, bodyBytes),
        tabType: tabType,
      ),
    );
  }

  // Note: ID 识别、精确匹配与目录回退见 .agents/notes/implemented/feature/2026-09-10-id-search.md
  Future<MediaItem?> lookupMediaById(String input) async {
    final id = input.trim();
    if (!isValidMediaId(id)) {
      throw const ApiException('作品 ID 需为 1 至 20 位数字，且不能全为 0');
    }
    Exception? failure;
    StackTrace? failureStack;
    for (final endpoint in ['detail', 'directory']) {
      try {
        final response = await _get(_url('/api/v1/books/$id/$endpoint', {}));
        final status = response.statusCode;
        final bytes = response.bodyBytes;
        final item = await Isolate.run(
          () => parseMediaIdResult(_decodeEnvelope(status, bytes), id),
        );
        if (item != null) return item;
      } on Exception catch (error, stack) {
        if (error is ApiException) {
          // BOOK_NOT_EXIST_ERROR is a definitive lookup result. Requesting
          // a directory for it adds delay and can obscure it with a timeout.
          if (error.upstreamCode == 101104) break;
          if (error.statusCode == 404) continue;
        }
        failure = error;
        failureStack = stack;
      }
    }
    // An unavailable source is retryable; it must not become "no results".
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    return null;
  }

  /// Book detail.
  Future<Map<String, dynamic>> detail(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await _get(
      _url('/api/detail', {'source': '番茄', 'book_id': bookId, 'tab': tab}),
    );
    return _decodeAsync(r);
  }

  /// Book directory — returns data.data.chapterListWithVolume.
  Future<Map<String, dynamic>> directory(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await _get(_directoryUrl(bookId, tab));
    return _decodeAsync(r);
  }

  /// Directory variant that performs decode + chapter normalization in the
  /// same background isolate.
  Future<List<List<Chapter>>> directoryChapters(
    String bookId, {
    String tab = '小说',
  }) async {
    final r = await _get(_directoryUrl(bookId, tab));
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(
      () => parseDirectory(_decodeEnvelope(statusCode, bodyBytes)),
    );
  }

  /// Chapter content (decrypted by backend).
  String _contentUrl(
    String itemId, {
    required String tab,
    String? toneId,
    String? mode,
  }) => _url('/api/content', {
    'source': '番茄',
    'item_id': itemId,
    'tab': tab,
    'tone_id': ?toneId,
    'mode': ?mode,
  });

  Future<Map<String, dynamic>> content(
    String itemId, {
    String tab = '小说',
    String? toneId,
    String? mode,
  }) async {
    final r = await _get(
      _contentUrl(itemId, tab: tab, toneId: toneId, mode: mode),
    );
    return _decodeAsync(r);
  }

  Future<BookDetail> bookDetail(String bookId) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/detail', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => BookDetail.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// Book reviews plus the counters shown above them.
  Future<BookCommentPage> bookComments(
    String bookId, {
    int count = 10,
    int offset = 0,
  }) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/comments', {
        'count': '$count',
        'offset': '$offset',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => BookCommentPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// Companion works: the original novel and any short-drama adaptation.
  Future<ChapterIdeas> chapterIdeas(
    String itemId, {
    String? itemVersion,
    int commentSource = 3,
  }) async {
    try {
      final response = await _get(
        _url('/api/v1/chapters/${Uri.encodeComponent(itemId)}/reviews', {
          'comment_source': '$commentSource',
          if (itemVersion != null && itemVersion.isNotEmpty)
            'item_version': itemVersion,
        }),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return await Isolate.run(() {
        final payload = _decodeEnvelope(status, bytes);
        if (isUnavailableIdeaCode(payload['code'])) return ChapterIdeas.empty;
        return ChapterIdeas.fromPayload(payload);
      });
    } on Exception {
      // Ideas are decoration; a failure must not break chapter loading.
      return ChapterIdeas.empty;
    }
  }

  /// Comment bodies for one paragraph.
  ///
  /// Note: `server_channel` must be **38**, not the 43 the official presenter
  /// assigns — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  ///
  /// This is the official client's paragraph-comment recipe, with one field
  /// corrected against live data. 43 (the decompiled presenter's value) is
  /// accepted (`code=0`) but always answers `total=0`. Channel 39 was the first
  /// fix — it matched the idea count on the two books verified then — but on
  /// other books (e.g. 7276384138653862966, 我不是戏神) it returns `total=0`
  /// while the idea list reports 77519. Channel **38** matches the idea count
  /// on every book tested, including those two, so it is the real paragraph
  /// channel and 39 was a partial mirror.
  ///
  /// The container is the **chapter item id** while `business_param.book_id`
  /// stays the real book id. All three of `book_id`, [itemVersion] and
  /// [paraIndex] are required: the upstream rejects the request with
  /// `103001 book_id, item_version, or para_index invalid` unless each is usable.
  Future<BookCommentPage> paragraphComments(
    String bookId,
    String itemId, {
    required String itemVersion,
    required int paraIndex,
    int count = 20,
    String? cursor,
  }) async {
    // Old saved catalogues have no version. Refresh it on demand instead of
    // turning a paragraph with a nonzero bubble count into an empty page.
    var version = itemVersion.trim();
    if (version.isEmpty) {
      final volumes = await directoryChapters(bookId);
      for (final chapter in volumes.expand((volume) => volume)) {
        if (chapter.itemId == itemId) {
          version = chapter.version.trim();
          break;
        }
      }
      if (version.isEmpty) {
        throw const ApiException('章节信息暂时无法加载');
      }
    }
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/reviews', {
        'book_id': bookId,
        'group_id': itemId,
        'group_type': '15',
        'comment_source': '2',
        'comment_type': '1',
        // 38 is the paragraph-comment channel that matches the idea count on
        // every book tested. 43 (the official presenter's value) is accepted
        // but always yields an empty list; 39 matched only some books.
        'server_channel': '38',
        'para_index': '$paraIndex',
        'item_version': version,
        'count': '$count',
        // Pagination token: the numeric `common_list_info.cursor` of the
        // previous page. Omitted on the first request so it stays byte for
        // byte identical with the verified recipe.
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => parseParagraphComments(_decodeEnvelope(status, bytes)),
    );
  }

  // --- Discovery: suggestions, hot search, authors, ranks ------------------

  /// Query suggestions for the text being typed. Returns an empty list on
  /// failure: the field is an aid, never a blocker to searching.
  Future<List<SearchSuggestion>> searchSuggestions(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final response = await _get(
        _url('/api/v1/search/suggest', {'q': trimmed}),
        timeout: const Duration(seconds: 10),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return await Isolate.run(
        () => SearchSuggestion.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return const [];
    }
  }

  /// The hot search board, used to fill the empty search screen.
  Future<HotSearch> hotSearch() async {
    try {
      final response = await _get(_url('/api/v1/search/hot', {}));
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return await Isolate.run(
        () => HotSearch.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return HotSearch.empty;
    }
  }

  /// Author profile plus their catalogue. Returns [AuthorProfile.empty] on
  /// failure so the page can show a retry instead of crashing.
  Future<AuthorProfile> authorProfile(String authorId) async {
    final response = await _get(
      _url('/api/v1/authors/${Uri.encodeComponent(authorId)}', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => AuthorProfile.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// The rank catalogue, which the upstream ships inside the novel homepage
  /// payload rather than on an endpoint of its own.
  Future<RankCatalog> rankCatalog() async {
    try {
      final response = await _get(_homepageUrl(2, 0, null));
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return await Isolate.run(
        () => RankCatalog.fromHomepagePayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return RankCatalog.empty;
    }
  }

  /// One page of a rank. [algo] is the catalogue's `rank_algo`, [categoryId] its
  /// `info_id` (0 = 全部).
  Future<RankBoard> rankBoard({
    required String rankId,
    required int algo,
    int categoryId = 0,
    int offset = 0,
    int startAt = 1,
  }) async {
    final response = await _get(
      _url('/api/v1/rank/${Uri.encodeComponent(rankId)}', {
        'algo_type': '$algo',
        'rank_sub_info_id': '$categoryId',
        if (offset > 0) 'offset': '$offset',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => RankCatalog.parsePage(
        _decodeEnvelope(status, bytes),
        startAt: startAt,
      ),
    );
  }

  /// Replies to one review. All three ids are required by the backend.
  Future<CommentReplyPage> commentReplies(
    String bookId,
    String commentId, {
    required String groupId,
    int count = 10,
  }) async {
    final response = await _get(
      _url('/api/v1/comments/${Uri.encodeComponent(commentId)}/replies', {
        'comment_id': commentId,
        'group_id': groupId,
        'book_id': bookId,
        'count': '$count',
      }),
      method: 'POST',
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => CommentReplyPage.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }

  /// Chapter previews for the given chapter item ids.
  Future<ChapterSummary> chapterSummaries(
    String bookId,
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return ChapterSummary.empty;
    try {
      final response = await _get(
        _url('/api/v1/books/${Uri.encodeComponent(bookId)}/chapters/summary', {
          'item_ids': itemIds.join(','),
        }),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      return await Isolate.run(
        () => ChapterSummary.fromPayload(_decodeEnvelope(status, bytes)),
      );
    } on Exception {
      return ChapterSummary.empty;
    }
  }

  /// Resolves specific comment bodies by id.  ///
  /// The idea list returns comment ids without bodies, so this is the second
  /// hop of the chapter-ideas chain: `insert_comment_ids` asks the comment list
  /// for exactly those entries. The container stays the chapter item id, which
  /// is what the upstream expects for comments anchored to a chapter.
  Future<BookCommentPage> commentsByIds(
    String bookId,
    String itemId,
    List<String> commentIds,
  ) async {
    if (commentIds.isEmpty) return const BookCommentPage();
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/reviews', {
        'book_id': bookId,
        'group_id': itemId,
        'insert_comment_ids': commentIds.join(','),
        'count': '${commentIds.length}',
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return Isolate.run(
      () => parseParagraphComments(_decodeEnvelope(status, bytes)),
    );
  }

  /// 短剧剧评（官方 `gx1/m.java:168-181`）：`:group_id` 是剧集 id。
  ///
  /// [sort] 1=最热（「全部」）、3=最新；[tag] 是服务端筛选标签，
  /// 非空时官方同时改用最新排序。
  Future<String> contentText(
    String itemId, {
    String tab = '小说',
    Duration? timeout,
  }) async {
    final r = await _get(_contentUrl(itemId, tab: tab), timeout: timeout);
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    return Isolate.run(() {
      final payload = _decodeEnvelope(statusCode, bodyBytes);
      return _extractChapterText(payload);
    });
  }

  // Note: 图文接口的解密标记与旧缓存升级见
  // .agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md
  Future<ChapterContent> chapterContent(String itemId) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _get(
        _url('/api/v1/chapters/${Uri.encodeComponent(itemId)}/novel', {}),
      );
      final status = response.statusCode;
      final bytes = response.bodyBytes;
      final baseUrl = _resourceBase;
      return await Isolate.run(() {
        final payload = _decodeEnvelope(status, bytes);
        final data = payload['data'];
        // Older backends return code=0 with ciphertext still in content.
        // Only consume a chapter the backend explicitly decrypted successfully.
        if (data is! Map ||
            data['content_decrypted'] != true ||
            data['content'] is! String) {
          throw const ApiException('图文正文尚未解密');
        }
        final content = parseChapterContent(
          data['content'] as String,
          baseUrl: baseUrl,
        );
        if (content.isEmpty) throw const ApiException('正文为空');
        return content;
      });
    } on Exception {
      // Keep text available if the illustrated source is temporarily down.
      // The cache records this as incomplete, allowing a later visit to retry.
      // A slow illustrated answer must not stack a second full timeout on top:
      // the fallback inherits the remaining budget (floored so a fast failure
      // still gets a real attempt), keeping the worst case near one timeout
      // instead of two.
      final remaining = _timeout - stopwatch.elapsed;
      final text = await contentText(
        itemId,
        timeout: remaining > const Duration(seconds: 5)
            ? remaining
            : const Duration(seconds: 5),
      );
      if (text.trim().isEmpty) throw const ApiException('正文为空');
      return ChapterContent.fromPlainText(text);
    }
  }

  /// Resolve a share URL to a book id.
  Future<Map<String, dynamic>> resolve(String url) async {
    final r = await _get(_url('/api/resolve', {'url': url}));
    return _decodeAsync(r);
  }

  /// Real homepage recommendations (the Flutter home page previously used a
  /// search for the literal word "推荐", which is not a recommendation API).
  ///
  /// [sessionId] must be echoed back when paging a tab (e.g. tab_type=8 看剧):
  /// the upstream binds the session to the device that opened it, and the
  /// backend pins that device across pages so pagination does not 101116.
  Future<Map<String, dynamic>> homepageRecommend({
    int tabType = 2,
    int offset = 0,
    String? sessionId,
  }) async {
    final r = await _get(_homepageUrl(tabType, offset, sessionId));
    return _decodeAsync(r);
  }

  /// Homepage variant that combines envelope decoding, recursive card
  /// extraction and cursor scanning in a single isolate hop.
  ///
  /// 官方短剧 feed 是**两段**：`/reading/bookapi/bookmall/tab` 只给出这个 tab 的
  /// cell（`cell_id_str`）和 session，视频流本身由
  /// `/reading/bookapi/bookmall/cell/change` 返回
  /// （`com/dragon/read/shortvideo/common/c.java`）。所以视频 tab 在第一段之后
  /// 追加第二段；第二段拿不到就退回第一段的结果，老后端没有第二段时行为不变。
  Future<HomepagePage> homepagePage({
    int tabType = 2,
    int offset = 0,
    String? sessionId,
  }) async {
    final r = await _get(_homepageUrl(tabType, offset, sessionId));
    final statusCode = r.statusCode;
    final bodyBytes = r.bodyBytes;
    final tab = await Isolate.run(() {
      final payload = _decodeEnvelope(statusCode, bodyBytes);
      int? nextOffset;
      String? nextSessionId;
      var selectedPayload = payload;
      final data = payload['data'];
      if (data is Map) {
        final tabItems = data['tab_item'];
        if (tabItems is List) {
          selectedPayload = <String, dynamic>{};
          for (final raw in tabItems) {
            if (raw is! Map || raw['tab_type']?.toString() != '$tabType') {
              continue;
            }
            selectedPayload = Map<String, dynamic>.from(raw);
            final candidate = raw['next_offset'];
            if (candidate is num &&
                candidate.toInt() > offset &&
                (nextOffset == null || candidate.toInt() > nextOffset)) {
              nextOffset = candidate.toInt();
            }
            final candidateSession = raw['session_id'];
            if (candidateSession is String && candidateSession.isNotEmpty) {
              nextSessionId = candidateSession;
            }
          }
        }
      }
      final items = parseMediaItems(selectedPayload, kind: null);
      return (
        page: HomepagePage(
          items: items,
          nextOffset: nextOffset,
          sessionId: nextSessionId,
        ),
        // 数字型 `cell_id` 在 JSON 里是 double，会被精度截断成上游认不出的值，
        // 必须取 `cell_id_str`。
        cellId: _firstStringField(payload, 'cell_id_str'),
      );
    });
    return tab.page;
  }

  /// 服务端频道表（F08）：官方 `GET /reading/bookapi/bookmall/tab/v`
  /// 的 `data.tab_item`（`TabDataList.tabItem`）+ `data.tab_index`
  /// （官方默认选中下标），客户端在 `m0.java:3051-3089` 把 `title` 当频道名、
  /// `tab_type` 当类型。失败/空表返回空表，由调用方回落到既有频道表。
  ///
  /// `tabType` 传当前频道的 `tab_type`；`lastTabType` 传上次选中频道的
  /// `tab_type`（官方存 SP `last_tab_type`，无值 -1），服务端用它算
  /// `tab_index` 续接用户位置。
  Future<ChannelTable> channelTabs({
    int tabType = 16,
    int lastTabType = -1,
  }) async {
    try {
      final r = await _get(
        _url('/api/v1/recommend/channels', {
          'tab_type': '$tabType',
          'last_tab_type': '$lastTabType',
        }),
      );
      final statusCode = r.statusCode;
      final bodyBytes = r.bodyBytes;
      return await Isolate.run(() {
        try {
          final payload = _decodeEnvelope(statusCode, bodyBytes);
          return ChannelTable.fromPayload(payload);
        } catch (_) {
          return ChannelTable.empty;
        }
      });
    } catch (_) {
      return ChannelTable.empty;
    }
  }

  String _homepageUrl(int tabType, int offset, String? sessionId) =>
      _url('/api/v1/recommend/homepage', {
        'tab_type': '$tabType',
        'offset': '$offset',
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      });

  /// Health check.
  Future<bool> health() async {
    try {
      final r = await _get(
        '$_base/health',
        timeout: const Duration(seconds: 3),
      );
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

String? _errorMessageFromBody(List<int> bodyBytes) {
  if (bodyBytes.isEmpty) return null;
  try {
    final decoded = jsonDecode(utf8.decode(bodyBytes));
    if (decoded is Map) {
      final payload = Map<String, dynamic>.from(decoded);
      for (final key in ['error', 'message']) {
        final value = payload[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    }
  } catch (_) {
    // Not a JSON error envelope; keep the HTTP status as the message.
  }
  return null;
}

Map<String, dynamic> _decodeEnvelope(int statusCode, List<int> bodyBytes) {
  if (statusCode != 200) {
    throw ApiException(
      _errorMessageFromBody(bodyBytes) ?? 'HTTP $statusCode',
      statusCode: statusCode,
    );
  }
  final decoded = jsonDecode(utf8.decode(bodyBytes));
  if (decoded is! Map) throw ApiException('响应格式错误');
  final payload = Map<String, dynamic>.from(decoded);
  // The web bridge uses code=200; REST upstream-compatible endpoints use
  // code=0. Both are successful envelopes.
  //
  // The "unavailable" codes are exempted rather than thrown: they mean "this
  // item has no subtitles / no paragraph comments", which the subtitle and
  // chapter-idea callers answer with an empty result. Throwing here made their
  // `isUnavailableCode`/`isUnavailableIdeaCode` guards unreachable dead code -
  // they only ever saw the exception path.
  if (payload['code'] != null &&
      payload['code'] != 200 &&
      payload['code'] != 0 &&
      !isUnavailableCode(payload['code']) &&
      !isUnavailableIdeaCode(payload['code'])) {
    throw ApiException(
      '${payload['message'] ?? '请求失败'}',
      upstreamCode: payload['code'] is int ? payload['code'] as int : null,
    );
  }
  if (payload['success'] == false) {
    throw ApiException('${payload['error'] ?? payload['message'] ?? '请求失败'}');
  }
  return payload;
}

String _extractChapterText(Map<String, dynamic> payload) {
  String visit(dynamic value, [int depth = 0]) {
    if (depth > 7 || value == null) return '';
    if (value is Map) {
      for (final key in ['content', 'text', 'article_content', 'body']) {
        final candidate = value[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return normalizeChapterText(candidate);
        }
      }
      for (final nested in value.values) {
        final result = visit(nested, depth + 1);
        if (result.isNotEmpty) return result;
      }
    } else if (value is List) {
      for (final nested in value) {
        final result = visit(nested, depth + 1);
        if (result.isNotEmpty) return result;
      }
    }
    return '';
  }

  return visit(payload);
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final int? upstreamCode;

  const ApiException(this.message, {this.statusCode, this.upstreamCode});

  @override
  String toString() => message;
}

/// 递归找第一个非空的字符串字段。官方 feed 的 cell id 藏在深层 cell 里，且
/// 数字写法会丢精度，只能按名字取字符串值。
String? _firstStringField(dynamic node, String key, [int depth = 0]) {
  if (depth > 16 || node == null) return null;
  if (node is Iterable) {
    for (final child in node) {
      final found = _firstStringField(child, key, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
  if (node is! Map) return null;
  final value = node[key];
  if (value is String && value.isNotEmpty) return value;
  if (value != null && value is num) return value.toString();
  for (final child in node.values) {
    final found = _firstStringField(child, key, depth + 1);
    if (found != null) return found;
  }
  return null;
}

/// 短剧 feed 里走官方第二段（`bookmall/cell/change`）的频道：推荐 16 / 看剧 8 / 漫剧 24。
///
/// 推荐频道尤其需要第二段：第一段只回 2 张卡且没有翻页游标，第二段回 5 张并给出游标
/// （实测 `series_title`/`video_data` 计数 2→5）。它的卡是模板卡（`show_type=407`），
/// 标题/封面走 `series_title`/`series_cover` 而不是 `title`/`cover`，且精确的系列 id
/// 在 `series_id_str`（数字型 `series_id` 已被上游截断）—— 这三处映射在
/// `models/media_item.dart` 的 `MediaItem.fromRaw` 里处理。
