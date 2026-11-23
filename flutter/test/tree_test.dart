import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scruter_flutter/scruter_flutter.dart';
import 'package:scruter_flutter/src/tree.dart';

class ProductCard extends StatelessWidget {
  const ProductCard(this.title, {super.key, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Row(children: [Text(title), IconButton(onPressed: () {}, icon: const Icon(Icons.add))]),
      );
}

ScreenTree tree(WidgetTester tester, {bool labels = false}) =>
    ScreenTree.build(tester.element(find.byType(Scaffold)).findAncestorStateOfType<NavigatorState>()!.context as Element, labels: labels);

(String, int) idOf(ScreenTree t, bool Function(TreeNode) f) => t.identify(t.nodes.firstWhere(f));

Future<void> pump(WidgetTester tester, Widget body) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));

void main() {
  testWidgets('explicit identifiers: ValueKey, Semantics, ScruterId; unstable ones are ignored', (tester) async {
    await pump(
      tester,
      Column(children: [
        ElevatedButton(key: const ValueKey('add_to_cart'), onPressed: () {}, child: const Text('a')),
        Semantics(identifier: 'checkout', child: TextButton(onPressed: () {}, child: const Text('b'))),
        ScruterId('more', child: OutlinedButton(onPressed: () {}, child: const Text('c'))),
        FilledButton(key: const ValueKey('item-12345678'), onPressed: () {}, child: const Text('d')),
      ]),
    );
    final t = tree(tester);
    expect(idOf(t, (n) => n.part == '#add_to_cart'), ('#add_to_cart', 0));
    final checkout = t.nodes.firstWhere((n) => n.part == '#checkout');
    expect(checkout.kind, 'button');
    expect(checkout.interactive, isTrue);
    final more = t.nodes.firstWhere((n) => n.part == '#more');
    expect(more.kind, 'button');
    expect(t.nodes.where((n) => n.part == 'OutlinedButton'), isEmpty, reason: 'one element, not two');
    expect(t.nodes.any((n) => n.part == 'FilledButton'), isTrue, reason: 'a generated key is no identifier');
  });

  testWidgets('type names survive as written; same selector, different index', (tester) async {
    await pump(
      tester,
      Column(children: [
        for (var i = 0; i < 3; i++) ElevatedButton(onPressed: () {}, child: Text('$i')),
      ]),
    );
    final t = tree(tester);
    final buttons = t.nodes.where((n) => n.part == 'ElevatedButton').toList();
    expect(buttons, hasLength(3));
    expect(t.identify(buttons[2]), ('ElevatedButton', 2));
    expect(buttons.first.kind, 'button');
  });

  testWidgets('context is added only when an equal selector has another parent chain', (tester) async {
    await pump(
      tester,
      Column(children: [
        Card(child: ElevatedButton(onPressed: () {}, child: const Text('in card'))),
        ElevatedButton(onPressed: () {}, child: const Text('alone')),
        ScruterId('gallery', child: Column(children: [Image.memory(_pixel), Image.memory(_pixel)])),
        Image.memory(_pixel),
      ]),
    );
    final t = tree(tester);
    final inCard = t.nodes.firstWhere((n) => n.part == 'ElevatedButton' && n.parent!.part == 'Card');
    expect(t.identify(inCard).$1, endsWith('Card/ElevatedButton'));
    final gallery = t.nodes.firstWhere((n) => n.part == 'Image' && n.parent!.part == '#gallery');
    expect(t.identify(gallery).$1, '#gallery/Image');
  });

  testWidgets('a list: every item shares a selector, the index is the item position', (tester) async {
    await pump(
      tester,
      KeyedSubtree(
        key: const ValueKey('holder'),
        child: ListView.builder(
          key: const ValueKey('products'),
          itemCount: 50,
          itemBuilder: (_, i) => ProductCard('Item $i', onTap: () {}),
        ),
      ),
    );
    final t = tree(tester);
    final cells = t.nodes.where((n) => n.item != null).toList();
    expect(cells.length, greaterThan(3));
    expect(cells.first.kind, 'cell');
    expect(cells.first.interactive, isTrue, reason: "the cell's InkWell is the cell");
    expect(t.identify(cells[3]), ('#products/ProductCard', 3));
    final icon = t.nodes.where((n) => n.part == 'IconButton').toList()[2];
    expect(t.identify(icon), ('#products/ProductCard/IconButton', 2));
  });

  testWidgets('a key of a list item is its data: not an identifier; ScruterId is', (tester) async {
    await pump(
      tester,
      ListView.builder(
        itemCount: 2,
        itemBuilder: (_, i) => i == 0 ? const Text('a', key: ValueKey('user-jane')) : ScruterId('hero', child: const Text('b')),
      ),
    );
    final t = tree(tester);
    final cells = t.nodes.where((n) => n.item != null).toList();
    expect(t.identify(cells[0]).$1, 'ListView/Text');
    expect(t.identify(cells[1]), ('ListView/#hero', 1));
  });

  testWidgets('children written one by one keep their keys: a form in a ListView', (tester) async {
    await pump(tester, ListView(children: const [TextField(key: ValueKey('email'))]));
    final t = tree(tester);
    final field = t.nodes.firstWhere((n) => n.item != null);
    expect(field.part, '#email');
    expect(field.kind, 'input');
    expect(field.isField, isTrue);
  });

  testWidgets('a button written in a list stays a button: forms read it as a submit', (tester) async {
    await pump(tester, ListView(children: [ElevatedButton(key: const ValueKey('pay'), onPressed: () {}, child: const Text('Payer'))]));
    final pay = tree(tester).nodes.firstWhere((n) => n.part == '#pay');
    expect(pay.kind, 'button');
    expect(pay.interactive, isTrue);
  });

  testWidgets('kinds', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(bottom: const TabBar(tabs: [Tab(text: 'a'), Tab(text: 'b')])),
          body: Column(children: [
            const TextField(),
            Checkbox(value: true, onChanged: (_) {}),
            Switch(value: true, onChanged: (_) {}),
            Slider(value: 0, onChanged: (_) {}),
            const Text('t'),
            Image.memory(_pixel),
            const Icon(Icons.add),
            GestureDetector(onTap: () {}, child: const SizedBox(width: 10, height: 10)),
          ]),
          floatingActionButton: FloatingActionButton(onPressed: () {}),
        ),
      ),
    ));
    final t = tree(tester);
    String kindOf(String part) => t.nodes.firstWhere((n) => n.part == part).kind;
    expect(kindOf('TextField'), 'input');
    expect(kindOf('Checkbox'), 'choice');
    expect(kindOf('Switch'), 'choice');
    expect(kindOf('Slider'), 'choice');
    expect(kindOf('Text'), 'text');
    expect(kindOf('Image'), 'image');
    expect(kindOf('Icon'), 'image');
    expect(kindOf('GestureDetector'), 'button');
    expect(kindOf('FloatingActionButton'), 'button');
    expect(t.nodes.where((n) => n.kind == 'tab'), hasLength(2));
  });

  testWidgets('offstage, hidden and masked content', (tester) async {
    await pump(
      tester,
      Column(children: [
        const Offstage(child: Text('offstage')),
        const Visibility(visible: false, maintainState: true, child: Text('hidden')),
        ScruterMask(child: Column(children: const [Text('secret')])),
        const TextField(),
      ]),
    );
    final t = tree(tester, labels: true);
    expect(t.nodes.where((n) => n.kind == 'text'), isEmpty);
    expect(t.nodes.where((n) => n.masked), hasLength(2));
    expect(t.nodes.every((n) => n.label == null), isTrue);
  });

  testWidgets('labels come only with a capture: nearest text, Semantics, tooltip', (tester) async {
    await pump(
      tester,
      Column(children: [
        ElevatedButton(onPressed: () {}, child: const Text('Add')),
        Semantics(label: 'Close', child: IconButton(onPressed: () {}, icon: const Icon(Icons.close))),
        IconButton(onPressed: () {}, tooltip: 'Plus', icon: const Icon(Icons.add)),
      ]),
    );
    expect(tree(tester).nodes.every((n) => n.label == null), isTrue);
    final t = tree(tester, labels: true);
    expect(t.nodes.firstWhere((n) => n.part == 'ElevatedButton').label, 'Add');
    expect(t.nodes.where((n) => n.part == 'IconButton').map((n) => n.label), ['Close', 'Plus']);
  });

  testWidgets('a long chain is cut at a /, the farthest context first', (tester) async {
    Widget deep(int n) => n == 0 ? ElevatedButton(onPressed: () {}, child: const Text('x')) : ScruterId('level_$n${'x' * 50}', child: deep(n - 1));
    await pump(tester, Column(children: [deep(1), deep(5)]));
    final t = tree(tester);
    final (s, _) = t.identify(t.nodes.lastWhere((n) => n.kind == 'button'));
    expect(s.runes.length, lessThanOrEqualTo(200));
  });

  testWidgets('a screen of 2 000 elements stays cheap', (tester) async {
    await pump(
      tester,
      SingleChildScrollView(
        child: Column(children: [for (var i = 0; i < 700; i++) Text('$i')]),
      ),
    );
    final root = tester.element(find.byType(Scaffold));
    final watch = Stopwatch()..start();
    final t = ScreenTree.build(root, hit: {tester.renderObject(find.text('350')): 0});
    final target = t.target()!;
    final id = t.identify(target);
    watch.stop();
    expect(id.$1, contains('Text'));
    expect(id.$2, 350);
    // A debug build on a CI machine: the budget of §3.18 is measured on the release build, in the example's checks.
    expect(watch.elapsedMilliseconds, lessThan(200));
  });
}

final _pixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0,
  0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0, 1, 0, 0, 5, 0, 1, 0x0D, 0x0A, 0x2D, 0xB4, 0,
  0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
