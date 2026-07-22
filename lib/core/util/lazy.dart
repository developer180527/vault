/// A value computed AT MOST ONCE — on first access — then reused for the whole
/// process lifetime. Use it for a deterministic computation whose result never
/// changes, so the cost is paid a single time instead of per build/frame.
///
/// For a plain field, Dart's `late final x = expr;` already gives compute-once
/// semantics; [Lazy] is for when you need to *hold* the un-computed thunk —
/// e.g. a top-level `final fooTable = Lazy(_buildFooTable);` shared across the
/// app, or a precomputed lookup you pass around before anyone forces it.
///
/// This is IN-MEMORY only: "static for the life of the app" resets on a cold
/// start, which is correct for pure computation (recomputing a constant on
/// launch is free). Persisting a computed result across restarts only earns its
/// keep when the computation is genuinely EXPENSIVE — for that, cache the
/// *result bytes* (see ContentCache), not the code that produces them.
class Lazy<T> {
  Lazy(this._compute);

  final T Function() _compute;
  bool _computed = false;
  late final T _value;

  /// Computes on first read, then returns the cached value forever after.
  T get value {
    if (!_computed) {
      _value = _compute();
      _computed = true;
    }
    return _value;
  }

  bool get isComputed => _computed;
}
