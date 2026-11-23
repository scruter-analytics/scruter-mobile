import 'package:flutter/material.dart';

/// The size budget (scripts/budget.sh): the same small app as `budget_with.dart`, without the SDK.
void main() {
  runApp(MaterialApp(home: Scaffold(body: Center(child: ElevatedButton(onPressed: () {}, child: const Text('x'))))));
}
