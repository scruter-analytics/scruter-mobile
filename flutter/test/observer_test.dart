import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

import 'support.dart';

Route<void> page(String? name, [Widget child = const SizedBox()]) =>
    MaterialPageRoute<void>(settings: RouteSettings(name: name), builder: (_) => child);

void main() {
  late GlobalKey<NavigatorState> nav;

  Future<void> app(WidgetTester tester, {ScruterObserver? observer}) async {
    nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      navigatorObservers: [observer ?? ScruterObserver()],
      initialRoute: '/',
      onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => Scaffold(body: Text(s.name ?? ''))),
    ));
    await tester.pump();
  }

  testWidgets('pushes and returns count like pages', (tester) async {
    final native = await startSdk(tester);
    await app(tester);
    expect(native.screens, ['/']);
    nav.currentState!.pushNamed('/cart');
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(native.screens, ['/', '/cart', '/']);
  });

  testWidgets('unnamed routes are not counted; going back counts the page again', (tester) async {
    final native = await startSdk(tester);
    await app(tester);
    nav.currentState!.push(page(null));
    await tester.pumpAndSettle();
    expect(native.screens, ['/']);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(native.screens, ['/', '/']);
  });

  testWidgets('an unnamed dialog stays part of the screen under it, a named one is a screen', (tester) async {
    final native = await startSdk(tester);
    await app(tester);
    showDialog<void>(context: nav.currentContext!, builder: (_) => const Text('x'));
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(native.screens, ['/']);
    showDialog<void>(context: nav.currentContext!, routeSettings: const RouteSettings(name: 'Confirm'), builder: (_) => const Text('x'));
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(native.screens, ['/', 'Confirm', '/']);
  });

  testWidgets('a query, a fragment and a value in the path never reach a name', (tester) async {
    final native = await startSdk(tester);
    await app(tester);
    nav.currentState!.pushNamed('/search?q=robe%20bleue');
    await tester.pumpAndSettle();
    nav.currentState!.pushNamed('/product/4242');
    await tester.pumpAndSettle();
    expect(native.screens, ['/', '/search', '/product/:id']);
  });

  testWidgets('replacing and removing routes', (tester) async {
    final native = await startSdk(tester);
    await app(tester);
    nav.currentState!.pushReplacementNamed('/login');
    await tester.pumpAndSettle();
    nav.currentState!.pushNamedAndRemoveUntil('/home', (_) => false);
    await tester.pumpAndSettle();
    expect(native.screens, ['/', '/login', '/home']);
  });

  testWidgets('nameExtractor names routes, null skips them', (tester) async {
    final native = await startSdk(tester);
    await app(tester, observer: ScruterObserver(nameExtractor: (s) => s.name == '/skip' ? null : 'Page ${s.name}'));
    nav.currentState!.pushNamed('/skip');
    await tester.pumpAndSettle();
    nav.currentState!.pushNamed('/kept');
    await tester.pumpAndSettle();
    expect(native.screens, ['Page /', 'Page /kept']);
  });

  testWidgets('Navigator 2: GoRouter rebuilds its pages, one navigation counts once', (tester) async {
    final native = await startSdk(tester);
    final router = GoRouter(observers: [ScruterObserver()], routes: [
      GoRoute(path: '/', name: 'Home', builder: (_, __) => const Text('h'), routes: [
        GoRoute(path: 'detail', name: 'Detail', builder: (_, __) => const Text('d')),
      ]),
      GoRoute(path: '/cart', name: 'Cart', builder: (_, __) => const Text('c')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/detail');
    await tester.pumpAndSettle();
    router.go('/cart');
    await tester.pumpAndSettle();
    expect(native.screens, ['Home', 'Detail', 'Cart']);
  });

  testWidgets('GoRouter: the route name, else the path pattern, never the parameters', (tester) async {
    final native = await startSdk(tester);
    final router = GoRouter(
      observers: [ScruterObserver()],
      routes: [
        GoRoute(path: '/', name: 'Home', builder: (_, __) => const Text('home'), routes: [
          GoRoute(path: 'cart', builder: (_, __) => const Text('cart')),
        ]),
        GoRoute(path: '/product/:id', builder: (_, s) => Text(s.pathParameters['id']!)),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.push('/product/1234?ref=mail');
    await tester.pumpAndSettle();
    router.go('/cart');
    await tester.pumpAndSettle();
    expect(native.screens.first, 'Home');
    expect(native.screens[1], '/product/:id');
    expect(native.screens.last, 'cart');
    expect(native.screens.join(), isNot(contains('1234')));
  });

  testWidgets('Scruter.screen names what the observer does not see, once', (tester) async {
    final native = await startSdk(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    Scruter.screen('Tab');
    await tester.pump();
    Scruter.screen('Tab');
    await tester.pump(const Duration(seconds: 1));
    expect(native.screens, ['Tab']);
  });

  testWidgets('before start, every call is a no-op', (tester) async {
    final native = FakeNative()..install();
    addTearDown(native.uninstall);
    Scruter.screen('x');
    Scruter.track('x');
    Scruter.optOut();
    await tester.pumpWidget(MaterialApp(navigatorObservers: [ScruterObserver()], home: const SizedBox()));
    await tester.pump();
    expect(native.calls, isEmpty);
  });
}
