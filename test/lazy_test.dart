import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/util/lazy.dart';

void main() {
  test('Lazy computes at most once, then reuses forever', () {
    var calls = 0;
    final memo = Lazy<int>(() {
      calls++;
      return 41 + calls;
    });

    expect(memo.isComputed, isFalse);
    expect(memo.value, 42); // first access computes
    expect(memo.isComputed, isTrue);
    expect(memo.value, 42); // subsequent accesses reuse — value never changes
    expect(memo.value, 42);
    expect(calls, 1, reason: 'the computation must run exactly once');
  });

  test('Lazy never runs the computation until first access', () {
    var ran = false;
    final memo = Lazy<String>(() {
      ran = true;
      return 'x';
    });
    expect(ran, isFalse); // holding the thunk does not force it
    memo.value;
    expect(ran, isTrue);
  });
}
