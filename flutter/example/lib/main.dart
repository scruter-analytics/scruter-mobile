import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

import 'self_check.dart';

/// Set for the self-check (scripts/device-check.mjs); a real app leaves them out.
const _endpoint = String.fromEnvironment('SCRUTER_ENDPOINT');
const _selfCheck = bool.fromEnvironment('SCRUTER_SELF_CHECK');

Future<void> main() async {
  final started = Stopwatch()..start();
  await Scruter.start(
    appId: 'ATMONA02',
    // From App settings › SDK, kept out of release builds: a release build that ships it never uses it anyway.
    debugKey: kDebugMode ? 'scr_dbg_${'a' * 43}' : null,
    debug: true,
    endpoint: _endpoint.isEmpty ? null : _endpoint,
    apiEndpoint: _endpoint.isEmpty ? null : _endpoint,
  );
  started.stop();
  runApp(const ShopApp());
  if (_selfCheck) await SelfCheck(router, navigatorKey, _endpoint, started.elapsedMicroseconds).run();
}

final navigatorKey = GlobalKey<NavigatorState>();

final router = GoRouter(
  navigatorKey: navigatorKey,
  observers: [ScruterObserver()],
  routes: [
    GoRoute(
      path: '/',
      name: 'Home',
      builder: (_, __) => const HomeScreen(),
      routes: [
        GoRoute(path: 'settings', name: 'Settings', builder: (_, __) => const SettingsScreen()),
      ],
    ),
    GoRoute(
      path: '/product/:id',
      builder: (_, state) => ProductScreen(id: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(path: '/checkout', name: 'Checkout', builder: (_, __) => const CheckoutScreen()),
    GoRoute(path: '/heavy', name: 'Measure', builder: (_, __) => const HeavyScreen()),
  ],
);

class ShopApp extends StatelessWidget {
  const ShopApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Atelier Mona',
        routerConfig: router,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF6B4EFF)),
      );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Atelier Mona'),
          actions: [
            IconButton(
              key: const ValueKey('settings'),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings),
              onPressed: () => context.go('/settings'),
            ),
          ],
        ),
        body: ListView.builder(
          key: const ValueKey('products'),
          itemCount: 60,
          itemBuilder: (_, i) => ProductTile(index: i),
        ),
      );
}

class ProductTile extends StatelessWidget {
  const ProductTile({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text('Product $index'),
        subtitle: Text('${49 + index} €'),
        onTap: () => context.push('/product/$index'),
      );
}

class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Product $id')),
        body: SingleChildScrollView(
          key: const ValueKey('details'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(height: 320, color: const Color(0xFFE4DDFF)),
              const Padding(padding: EdgeInsets.all(16), child: Text('A description with no link, which does not react.')),
              for (var i = 0; i < 12; i++) Padding(padding: const EdgeInsets.all(16), child: Text('Detail $i')),
              const ScruterMask(child: Padding(padding: EdgeInsets.all(16), child: Text('Your address: 12 Lilac Street'))),
              Padding(
                padding: const EdgeInsets.all(16),
                child: ScruterId(
                  'addToCart',
                  child: ElevatedButton(
                    onPressed: () {
                      Scruter.track('Add to cart', props: {'color': 'blue'}, revenue: 49.0, currency: 'EUR');
                      context.push('/checkout');
                    },
                    child: const Text('Add to cart'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _form = GlobalKey<FormState>();
  bool _news = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Checkout')),
        body: ScruterForm(
          'Delivery',
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextFormField(
                  key: const ValueKey('email'),
                  autofillHints: const [AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'E-mail'),
                  validator: (v) => (v ?? '').contains('@') ? null : 'Invalid e-mail',
                ),
                TextFormField(
                  key: const ValueKey('postalCode'),
                  autofillHints: const [AutofillHints.postalCode],
                  decoration: const InputDecoration(labelText: 'Postal code'),
                  validator: (v) => (v ?? '').length == 5 ? null : '5 digits',
                ),
                TextFormField(
                  key: const ValueKey('accountPassword'),
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                SwitchListTile(
                  key: const ValueKey('news'),
                  title: const Text('Receive the news'),
                  value: _news,
                  onChanged: (v) => setState(() => _news = v),
                ),
                ElevatedButton(
                  key: const ValueKey('pay'),
                  onPressed: () {
                    if (_form.currentState!.validate()) {
                      Scruter.formSent('Delivery');
                      Scruter.track('Order placed', revenue: 49.0, currency: 'EUR');
                      context.go('/');
                    }
                  },
                  child: const Text('Pay'),
                ),
              ],
            ),
          ),
        ),
      );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _measured = true;

  @override
  void initState() {
    super.initState();
    Scruter.isOptedOut.then((v) {
      if (mounted) setState(() => _measured = !v);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: SwitchListTile(
          key: const ValueKey('measure'),
          title: const Text('Audience measurement'),
          value: _measured,
          onChanged: (v) {
            setState(() => _measured = v);
            v ? Scruter.optIn() : Scruter.optOut();
          },
        ),
      );
}

/// A worst case for the budgets of the self-check: 2 000 elements on one screen.
class HeavyScreen extends StatelessWidget {
  const HeavyScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [for (var i = 0; i < 2000; i++) SizedBox(width: double.infinity, height: 2, child: Text('$i', key: i == 1000 ? const ValueKey('middle') : null))]),
        ),
      );
}
