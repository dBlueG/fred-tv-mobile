import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/native_bridge.dart';

// The livestreams of the list a channel was opened from, so the player can
// switch to the next or previous one. Loads further pages on demand.
class ChannelPlaylist {
  static const _pageSize = 36;

  final Filters _filters;
  final List<Channel> _loaded;
  bool _reachedEnd;
  int _index;

  ChannelPlaylist._(this._filters, this._loaded, this._reachedEnd, this._index);

  // Returns null when there is nothing to switch to.
  static ChannelPlaylist? create({
    required Filters filters,
    required List<Channel> channels,
    required Channel current,
    required bool reachedEnd,
  }) {
    if (current.mediaType != MediaType.livestream) return null;
    final index = channels.indexOf(current);
    if (index < 0) return null;
    final live = channels.where(_isLive).length;
    if (live < 2 && reachedEnd) return null;
    return ChannelPlaylist._(
      filters.copy(),
      List.of(channels),
      reachedEnd,
      index,
    );
  }

  static bool _isLive(Channel c) =>
      c.mediaType == MediaType.livestream && c.url != null;

  Channel get current => _loaded[_index];

  // Moves to the next (delta > 0) or previous (delta < 0) livestream. Wraps
  // around once the whole list is loaded. Returns null if there is none.
  Future<Channel?> step(int delta) async {
    final direction = delta > 0 ? 1 : -1;
    var i = _index;
    for (var tries = 0; tries <= _loaded.length + _pageSize; tries++) {
      i += direction;
      if (i >= _loaded.length) {
        if (!_reachedEnd && await _loadNextPage()) {
          i = i.clamp(0, _loaded.length - 1);
        } else {
          i = 0;
        }
      } else if (i < 0) {
        // Can't wrap backwards without knowing where the list ends.
        if (!_reachedEnd) return null;
        i = _loaded.length - 1;
      }
      if (i == _index) return null;
      if (_isLive(_loaded[i])) {
        _index = i;
        return _loaded[i];
      }
    }
    return null;
  }

  Future<bool> _loadNextPage() async {
    _filters.page++;
    final List<Channel> page;
    try {
      page = await NativeBridge.instance.getChannels(_filters);
    } catch (_) {
      _filters.page--;
      return false;
    }
    _reachedEnd = page.length < _pageSize;
    _loaded.addAll(page);
    return page.isNotEmpty;
  }
}
