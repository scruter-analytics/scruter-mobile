import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/src/text.dart';

void main() {
  test('clean removes control and format characters, trims, cuts in code points', () {
    expect(ScruterText.clean('  a\u0000b​c\n ', 120), 'abc');
    expect(ScruterText.clean(' \n', 120), isNull);
    expect(ScruterText.clean('😀😀😀', 2), '😀😀');
  });

  test('stable identifiers (§3.5)', () {
    for (final id in ['addToCart', 'add_to_cart', 'checkout.pay:1', 'a-b']) {
      expect(ScruterText.isStableId(id), isTrue, reason: id);
    }
    for (final id in [
      '',
      '1abc',
      'item 1',
      'order12345',
      'a' * 61,
      'user@mail',
      'ab12cd34',
      '123e4567-e89b-12d3-a456-426614174000',
    ]) {
      expect(ScruterText.isStableId(id), isFalse, reason: id);
    }
  });

  test('sensitive names (§3.9)', () {
    for (final n in ['cardNumber', 'CVC', 'iban', 'pinCode', 'otp', 'authToken', 'clientSecret', 'password']) {
      expect(ScruterText.isSensitiveName(n), isTrue, reason: n);
    }
    expect(ScruterText.isSensitiveName('postalCode'), isFalse);
  });

  test('type names: generics and leading underscores removed, obfuscated names give nothing', () {
    expect(ScruterText.typeName('_ProductCard<int>'), 'ProductCard');
    expect(ScruterText.typeName('aB'), isNull);
    expect(ScruterText.typeName('X' * 50)!.length, 40);
  });

  test('route names never hold parameters', () {
    expect(ScruterText.routeName('/product/:id'), '/product/:id');
    expect(ScruterText.routeName('/search?q=shoes#top'), '/search');
    expect(ScruterText.routeName('/product/42'), '/product/:id');
    expect(ScruterText.routeName('/order/123e4567-e89b-12d3-a456-426614174000/done'), '/order/:id/done');
    expect(ScruterText.routeName('/user/ab12cd34ef'), '/user/:id');
    expect(ScruterText.routeName('Cart'), 'Cart');
    expect(ScruterText.routeName('/settings/notifications'), '/settings/notifications');
  });
}
