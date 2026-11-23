import 'package:flutter/material.dart';
import 'package:scruter_flutter/scruter_flutter.dart';

/// The size budget (scripts/budget.sh): what the SDK's Dart layer adds to a small app (docs/MOBILE.md §3.18).
Future<void> main() async {
  await Scruter.start(appId: 'ATMONA02');
  runApp(MaterialApp(
    navigatorObservers: [ScruterObserver()],
    home: Scaffold(body: Center(child: ElevatedButton(onPressed: () => Scruter.track('x'), child: const Text('x')))),
  ));
}
