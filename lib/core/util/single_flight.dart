/// Coalesces concurrent calls into ONE execution.
///
/// Extracted from the session's token refresh, where getting this wrong is
/// expensive: refresh tokens are single-use and rotate server-side, so if
/// several providers each POST the same token at startup the first rotates it
/// and the rest present a stale one — past the server's grace window that
/// REVOKES the device, and their out-of-order persists can store a stale token
/// that bricks the next launch.
///
/// It lives here, separately, because the failure modes are concurrency-shaped
/// and deserve tests of their own rather than being provable only by reading.
class SingleFlight<T> {
  Future<T>? _inflight;

  /// True while an execution is in progress.
  bool get isRunning => _inflight != null;

  /// Runs [action], or joins the execution already in flight.
  ///
  /// Every caller — the one that started it and everyone who joined — gets the
  /// same result, success or failure. Once it settles the slot is released, so
  /// a later call runs [action] again (a failure is not cached).
  Future<T> run(Future<T> Function() action) {
    final existing = _inflight;
    if (existing != null) return existing;

    final f = action();
    _inflight = f;

    // Release the slot, but only if a later run hasn't already replaced us.
    //
    // .ignore() is load-bearing. whenComplete() returns a NEW future mirroring
    // f's outcome, error included; discarding it leaves that copy unlistened,
    // and an unlistened error becomes an UNCAUGHT zone error. That is exactly
    // how an offline token refresh got logged as `FATAL Uncaught error` on a
    // path the caller had already handled. The real error still reaches callers
    // through the future returned below — only the duplicate is silenced.
    f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    }).ignore();

    return f;
  }
}
