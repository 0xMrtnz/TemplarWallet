import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/app/back_handler.dart';

void main() {
  test('newest handler is asked first; the first to consume wins', () {
    final order = <String>[];
    bool a() {
      order.add('a');
      return true;
    }

    bool b() {
      order.add('b');
      return false;
    }

    final reg = BackHandler.instance;
    reg.push(a);
    reg.push(b);
    expect(reg.hasHandlers, isTrue);
    expect(reg.dispatch(), isTrue);
    expect(order, ['b', 'a']);
    reg.remove(a);
    reg.remove(b);
    expect(reg.hasHandlers, isFalse);
    expect(reg.dispatch(), isFalse);
  });

  test('listeners are told a microtask later, once per burst', () async {
    final reg = BackHandler.instance;
    var notified = 0;
    void listen() => notified++;
    reg.addListener(listen);
    bool h() => true;
    reg.push(h);
    reg.remove(h);
    expect(notified, 0);
    await Future<void>.delayed(Duration.zero);
    expect(notified, 1);
    reg.removeListener(listen);
  });
}
