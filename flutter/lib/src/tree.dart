import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'text.dart';
import 'widgets.dart';

/// One element that means something on a screen (docs/MOBILE.md §3.5). A Flutter element tree holds dozens of elements
/// per button: only these become nodes, so that the identity's levels and depth-first positions are the app's and do
/// not change with Flutter's internals.
class TreeNode {
  TreeNode(this.element, this.parent, this.part, this.kind, {this.explicit = false, this.interactive = false, this.open = false, this.item}) {
    parent?.children.add(this);
    depth = (parent?.depth ?? -1) + 1;
  }

  final Element element;
  final TreeNode? parent;
  final List<TreeNode> children = [];
  late final int depth;

  /// `#id`, else the type's name, plus `[kind]` when the type says nothing.
  String part;
  String kind;
  bool explicit;
  bool interactive;

  /// Still without a role: the first classified element under it gives its own (`ScruterId(child: ElevatedButton)`, a
  /// list item holding an `InkWell`).
  bool open;

  /// The item position when the node is a list or grid item.
  final int? item;
  bool masked = false;
  bool ignored = false;
  String? form;

  /// A form field (§3.9): a text input or a choice.
  bool isField = false;

  /// The element of the field's own widget, under a keyed wrapper (`TextFormField` around its `TextField`).
  Element? fieldElement;

  /// A text input's [EditableText], for forms (focus node, controller, hints): never read for its text.
  EditableText? editable;

  /// A text input's autofill types.
  Iterable<String>? autofillHints;

  /// A choice's field type.
  String? choice;

  /// Accessibility label, else visible text: team phones' capture only (§3.5 step 3).
  String? label;
  List<String>? _chain;

  /// The parts of the ancestors, nearest first, below the tree's root.
  List<String> chain() {
    final known = _chain;
    if (known != null) return known;
    final out = <String>[];
    var a = parent;
    while (a != null && a.parent != null && out.length < 64) {
      out.add(a.part);
      a = a.parent;
    }
    return _chain = out;
  }

  bool get inItem {
    for (TreeNode? n = this; n != null && n.parent != null; n = n.parent) {
      if (n.item != null) return true;
    }
    return false;
  }
}

/// What a widget type is, computed once per runtime type.
class _Info {
  const _Info(this.name, this.kind, {this.role = _Role.plain, this.leaf = false, this.container = false, this.choice});

  /// The name in selectors, spelled here so that it survives `--obfuscate`.
  final String name;
  final String kind;
  final _Role role;

  /// Nothing under it is a node.
  final bool leaf;
  final bool container;
  final String? choice;
}

enum _Role { plain, button, gesture, input, choice, media }

/// The platform views of `webview_flutter` and `flutter_inappwebview`: `web` in the tree, whatever the app's types.
const _webViewTypes = <String>{'plugins.flutter.io/webview', 'com.pichillilorenzo/flutter_inappwebview'};

const _text = _Info('Text', 'text', leaf: true);

/// The nodes of a screen, depth first, and the target of a hit.
class ScreenTree {
  ScreenTree._(Element root) : root = TreeNode(root, null, 'View[other]', 'other');

  /// Builds the tree under [rootElement]. [hit]: render objects of a hit test, deepest first: [hitNode] is then the
  /// node at the deepest of them. [labels]: reads labels and visible text, on team phones only. Only what is on stage is
  /// walked: not the routes under an opaque one, not the list items out of the viewport.
  static ScreenTree build(Element rootElement, {Map<Object, int>? hit, bool labels = false}) {
    final t = ScreenTree._(rootElement);
    t._hit = hit;
    t._labels = labels;
    t._walk(rootElement, t.root);
    return t;
  }

  final TreeNode root;
  final List<TreeNode> nodes = [];
  Map<Object, int>? _hit;
  bool _labels = false;
  int _hitRank = 1 << 30;
  TreeNode? hitNode;
  String? _form;
  String? _pendingLabel;
  bool _inTabs = false;

  /// Inside a button or a choice: the widgets it builds for itself are not elements of their own (`IconButton` is a
  /// `ButtonStyleButton` in Material 3, `SwitchListTile` holds a `Switch`).
  bool _inControl = false;

  /// Under an interactive element: its texts and images are never targets, they only name it (§3.5 step 1).
  bool _underInteractive = false;

  /// Gesture widgets that a button or an `InkWell` builds for itself are not nodes of their own.
  int _absorbing = 0;

  static final Map<Type, _Info?> _types = {};

  static _Info? _info(Widget w) {
    final t = w.runtimeType;
    final known = _types[t];
    if (known != null || _types.containsKey(t)) return known;
    return _types[t] = _classify(w);
  }

  static _Info? _classify(Widget w) {
    if (w is Text || w is RichText) return w is Text ? _text : const _Info('RichText', 'text', leaf: true);
    if (w is Image) return const _Info('Image', 'image', leaf: true);
    if (w is Icon) return const _Info('Icon', 'image', leaf: true);
    if (w is RawImage) return const _Info('RawImage', 'image', leaf: true);
    if (w is CircleAvatar) return const _Info('CircleAvatar', 'image');
    if (w is ElevatedButton) return const _Info('ElevatedButton', 'button', role: _Role.button);
    if (w is FilledButton) return const _Info('FilledButton', 'button', role: _Role.button);
    if (w is OutlinedButton) return const _Info('OutlinedButton', 'button', role: _Role.button);
    if (w is TextButton) return const _Info('TextButton', 'button', role: _Role.button);
    if (w is ButtonStyleButton) return const _Info('Button', 'button', role: _Role.button);
    if (w is IconButton) return const _Info('IconButton', 'button', role: _Role.button);
    if (w is FloatingActionButton) return const _Info('FloatingActionButton', 'button', role: _Role.button);
    if (w is CupertinoButton) return const _Info('CupertinoButton', 'button', role: _Role.button);
    if (w is PopupMenuButton) return const _Info('PopupMenuButton', 'button', role: _Role.button);
    if (w is ListTile) return const _Info('ListTile', 'other', role: _Role.gesture);
    if (w is InkResponse) return _Info(w is InkWell ? 'InkWell' : 'InkResponse', 'other', role: _Role.gesture);
    if (w is GestureDetector) return const _Info('GestureDetector', 'other', role: _Role.gesture);
    if (w is RawGestureDetector) return const _Info('RawGestureDetector', 'other', role: _Role.gesture);
    if (w is TextField) return const _Info('TextField', 'input', role: _Role.input);
    if (w is CupertinoTextField) return const _Info('CupertinoTextField', 'input', role: _Role.input);
    if (w is EditableText) return const _Info('EditableText', 'input', role: _Role.input);
    if (w is CheckboxListTile) return const _Info('CheckboxListTile', 'choice', role: _Role.choice, choice: 'checkbox');
    if (w is SwitchListTile) return const _Info('SwitchListTile', 'choice', role: _Role.choice, choice: 'switch');
    if (w is RadioListTile) return const _Info('RadioListTile', 'choice', role: _Role.choice, choice: 'radio');
    if (w is Checkbox) return const _Info('Checkbox', 'choice', role: _Role.choice, choice: 'checkbox');
    if (w is Switch) return const _Info('Switch', 'choice', role: _Role.choice, choice: 'switch');
    if (w is Radio) return const _Info('Radio', 'choice', role: _Role.choice, choice: 'radio');
    if (w is Slider) return const _Info('Slider', 'choice', role: _Role.choice, choice: 'slider');
    if (w is RangeSlider) return const _Info('RangeSlider', 'choice', role: _Role.choice, choice: 'slider');
    if (w is DropdownButton) return const _Info('DropdownButton', 'choice', role: _Role.choice, choice: 'select');
    if (w is DropdownMenu) return const _Info('DropdownMenu', 'choice', role: _Role.choice, choice: 'select');
    if (w is SegmentedButton) return const _Info('SegmentedButton', 'choice', role: _Role.choice, choice: 'choice');
    if (w is ToggleButtons) return const _Info('ToggleButtons', 'choice', role: _Role.choice, choice: 'choice');
    if (w is ChipAttributes) return const _Info('Chip', 'choice', role: _Role.choice, choice: 'choice');
    if (w is CupertinoSwitch) return const _Info('CupertinoSwitch', 'choice', role: _Role.choice, choice: 'switch');
    if (w is CupertinoCheckbox) return const _Info('CupertinoCheckbox', 'choice', role: _Role.choice, choice: 'checkbox');
    if (w is CupertinoSlider) return const _Info('CupertinoSlider', 'choice', role: _Role.choice, choice: 'slider');
    if (w is CupertinoSegmentedControl) return const _Info('CupertinoSegmentedControl', 'choice', role: _Role.choice, choice: 'choice');
    if (w is CupertinoSlidingSegmentedControl) return const _Info('CupertinoSlidingSegmentedControl', 'choice', role: _Role.choice, choice: 'choice');
    if (w is CupertinoPicker) return const _Info('CupertinoPicker', 'choice', role: _Role.choice, choice: 'select');
    if (w is CupertinoDatePicker) return const _Info('CupertinoDatePicker', 'choice', role: _Role.choice, choice: 'date');
    if (w is PlatformViewLink || w is AndroidView || w is UiKitView || w is Texture) {
      return const _Info('PlatformView', 'media', role: _Role.media, leaf: true);
    }
    if (w is ListView) return const _Info('ListView', 'container', container: true);
    if (w is GridView) return const _Info('GridView', 'container', container: true);
    if (w is CustomScrollView) return const _Info('CustomScrollView', 'container', container: true);
    if (w is ScrollView) return const _Info('ScrollView', 'container', container: true);
    if (w is SingleChildScrollView) return const _Info('SingleChildScrollView', 'container', container: true);
    if (w is PageView) return const _Info('PageView', 'container', container: true);
    if (w is TabBarView) return const _Info('TabBarView', 'container', container: true);
    if (w is ReorderableListView) return const _Info('ReorderableListView', 'container', container: true);
    if (w is Scaffold) return const _Info('Scaffold', 'container', container: true);
    if (w is CupertinoPageScaffold) return const _Info('CupertinoPageScaffold', 'container', container: true);
    if (w is CupertinoTabScaffold) return const _Info('CupertinoTabScaffold', 'container', container: true);
    if (w is AppBar) return const _Info('AppBar', 'container', container: true);
    if (w is SliverAppBar) return const _Info('SliverAppBar', 'container', container: true);
    if (w is CupertinoNavigationBar) return const _Info('CupertinoNavigationBar', 'container', container: true);
    if (w is Card) return const _Info('Card', 'container', container: true);
    if (w is Drawer) return const _Info('Drawer', 'container', container: true);
    if (w is AlertDialog) return const _Info('AlertDialog', 'container', container: true);
    if (w is Dialog) return const _Info('Dialog', 'container', container: true);
    if (w is BottomSheet) return const _Info('BottomSheet', 'container', container: true);
    if (w is TabBar) return const _Info('TabBar', 'container', container: true);
    if (w is NavigationBar) return const _Info('NavigationBar', 'container', container: true);
    if (w is NavigationRail) return const _Info('NavigationRail', 'container', container: true);
    if (w is BottomNavigationBar) return const _Info('BottomNavigationBar', 'container', container: true);
    if (w is CupertinoTabBar) return const _Info('CupertinoTabBar', 'container', container: true);
    return null;
  }

  static bool _tabBar(Widget w) =>
      w is TabBar || w is NavigationBar || w is NavigationRail || w is BottomNavigationBar || w is CupertinoTabBar;

  /// Whether a widget of a given role reacts to touches now: a disabled button does not.
  static bool _reacts(Widget w, _Role role) {
    if (role == _Role.button) {
      if (w is ButtonStyleButton) return w.enabled;
      if (w is IconButton) return w.onPressed != null;
      if (w is FloatingActionButton) return w.onPressed != null;
      if (w is CupertinoButton) return w.enabled;
      if (w is PopupMenuButton) return w.enabled;
      return true;
    }
    if (role == _Role.choice) {
      if (w is Checkbox) return w.onChanged != null;
      if (w is Switch) return w.onChanged != null;
      // ignore: deprecated_member_use
      if (w is Radio) return w.onChanged != null;
      if (w is Slider) return w.onChanged != null;
      if (w is DropdownButton) return w.onChanged != null;
      if (w is CheckboxListTile) return w.onChanged != null;
      if (w is SwitchListTile) return w.onChanged != null;
      return true;
    }
    if (role == _Role.input) {
      if (w is TextField) return w.enabled ?? true;
      return true;
    }
    if (w is ListTile) return (w.onTap != null || w.onLongPress != null) && w.enabled;
    if (w is InkResponse) {
      return w.onTap != null || w.onLongPress != null || w.onDoubleTap != null || w.onTapDown != null || w.onTapUp != null;
    }
    if (w is GestureDetector) {
      return w.onTap != null || w.onLongPress != null || w.onDoubleTap != null || w.onTapDown != null || w.onTapUp != null ||
          w.onSecondaryTap != null || w.onLongPressStart != null || w.onVerticalDragStart != null || w.onVerticalDragUpdate != null ||
          w.onHorizontalDragStart != null || w.onHorizontalDragUpdate != null || w.onPanStart != null || w.onPanUpdate != null ||
          w.onScaleStart != null || w.onScaleUpdate != null || w.onForcePressStart != null;
    }
    if (w is RawGestureDetector) {
      return w.gestures.keys.any((t) => t == TapGestureRecognizer || t == LongPressGestureRecognizer || t == DoubleTapGestureRecognizer);
    }
    return false;
  }

  /// A stable explicit identifier of the widget itself: `ScruterId`, a `ValueKey<String>`, `Semantics(identifier:)`.
  /// A list item's keys are its data's, so an item has one only through `ScruterId`.
  static String? _explicit(Widget w, {required bool item}) {
    if (w is ScruterId) return w.id;
    if (item) return null;
    final k = w.key;
    if (k is ValueKey<String>) return k.value;
    if (w is Semantics) {
      final id = w.properties.identifier;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  void _note(Object render, TreeNode at) {
    final hit = _hit;
    if (hit == null) return;
    final rank = hit[render];
    if (rank != null && rank < _hitRank) {
      _hitRank = rank;
      hitNode = at;
    }
  }

  void _children(Element e, TreeNode parent) {
    e.debugVisitOnstageChildren((c) => _walk(c, parent));
  }

  void _walk(Element e, TreeNode parent) {
    final w = e.widget;
    if (w is Visibility && !w.visible) return;
    if (e is RenderObjectElement) _note(e.renderObject, parent);
    if (w is ScruterIgnore || w is ScruterMask) {
      final n = TreeNode(e, parent, 'View[other]', 'other');
      n.masked = w is ScruterMask;
      n.ignored = w is ScruterIgnore;
      nodes.add(n);
      _markHits(e, n);
      return;
    }
    if (e is SliverMultiBoxAdaptorElement) {
      // Children written one by one (`ListView(children: …)`, a form) have keys of the app's, a builder's are its data's.
      final written = (w as SliverMultiBoxAdaptorWidget).delegate is SliverChildListDelegate;
      e.debugVisitOnstageChildren((c) => _item(c, parent, written: written));
      return;
    }
    if (_labels) _wrapperLabel(w, parent);
    final savedForm = _form;
    final savedTabs = _inTabs;
    final savedControl = _inControl;
    final savedInteractive = _underInteractive;
    if (w is ScruterForm) _form = w.name;
    if (_tabBar(w)) _inTabs = true;

    var here = parent;
    final info = _info(w);
    final id = _explicit(w, item: false);
    if (id != null || info != null) here = _enter(e, w, info, id, parent);
    if (w is Form && id != null && ScruterText.isStableId(id) && _form == null) _form = id;
    if (here.interactive) _underInteractive = true;
    if (info == null || !info.leaf) {
      if (info?.role == _Role.input) {
        _input(e, here);
      } else {
        final absorbed = _absorbing;
        _absorb(w, info);
        _children(e, here);
        _absorbing = absorbed;
      }
    } else {
      _markHits(e, here);
      if (_labels) _leafLabel(w, here);
    }
    _form = savedForm;
    _inTabs = savedTabs;
    _inControl = savedControl;
    _underInteractive = savedInteractive;
  }

  void _absorb(Widget w, _Info? info) {
    final control = info?.role == _Role.button || info?.role == _Role.choice;
    if (control) _inControl = true;
    if (control || w is ListTile) {
      _absorbing = 3;
    } else if (w is InkResponse) {
      _absorbing = 2;
    } else if (w is GestureDetector) {
      _absorbing = 1;
    } else if (w is RawGestureDetector) {
      _absorbing = 0;
    }
  }

  /// Hits under a node that is not walked (a leaf, a masked element) are that node's.
  void _markHits(Element e, TreeNode n) {
    if (_hit == null) return;
    void down(Element x) {
      if (x is RenderObjectElement) _note(x.renderObject, n);
      x.visitChildren(down);
    }

    down(e);
  }

  TreeNode _enter(Element e, Widget w, _Info? info, String? id, TreeNode parent) {
    final role = info?.role ?? _Role.plain;
    final gesture = role == _Role.gesture;
    if (info != null && info.leaf && role == _Role.plain && _underInteractive && id == null) return parent;
    if (gesture && _absorbing > 0) return parent;
    if (gesture && !_reacts(w, role) && id == null) return parent;
    if (_inControl && id == null && (role == _Role.button || role == _Role.choice || gesture)) return parent;
    final field = role == _Role.input || role == _Role.choice;
    final stable = id != null && ScruterText.isStableId(id);
    final reacts = role != _Role.plain && role != _Role.media && _reacts(w, role);
    // A node still without a role takes this one's.
    if (parent.open && !stable && info != null && !info.container) {
      parent.open = false;
      parent.interactive = parent.interactive || reacts;
      if (parent.item == null || field) parent.kind = _kindOf(info, reacts);
      if (field) {
        parent.isField = true;
        parent.fieldElement = e;
        parent.choice = info.choice;
      }
      if (role == _Role.media) {
        parent.masked = true;
        parent.kind = _mediaKind(w);
      }
      if (_labels) _takeLabel(parent);
      return parent;
    }
    if (info == null && !stable) return parent;
    final kind = info == null ? 'other' : _kindOf(info, reacts);
    final part = stable ? '#$id' : _partOf(w, info, kind);
    final n = TreeNode(e, parent, part, kind, explicit: stable, interactive: reacts, open: info == null && w is! Form);
    n.form = _form;
    n.choice = info?.choice;
    n.isField = field;
    if (role == _Role.media) {
      n.masked = true;
      n.kind = _mediaKind(w);
    }
    if (_labels) _takeLabel(n);
    nodes.add(n);
    return n;
  }

  /// A view type is per instance, so not in the per-type [_Info].
  static String _mediaKind(Widget w) {
    final String? type = w is PlatformViewLink
        ? w.viewType
        : w is AndroidView
            ? w.viewType
            : w is UiKitView
                ? w.viewType
                : null;
    return _webViewTypes.contains(type) ? 'web' : 'media';
  }

  String _kindOf(_Info info, bool reacts) {
    if (_inTabs && reacts) return 'tab';
    if (info.role == _Role.gesture) return 'button';
    return info.kind;
  }

  static String _partOf(Widget w, _Info? info, String kind) => info?.name ?? '${_customName(w) ?? 'View'}[$kind]';

  static String? _customName(Widget w) => ScruterText.typeName(w.runtimeType.toString());

  /// A label on a wrapper names the element under it, or the control that built it (a button's tooltip).
  void _wrapperLabel(Widget w, TreeNode parent) {
    final String? l = w is Semantics ? w.properties.label : (w is Tooltip ? w.message : null);
    if (l == null || l.isEmpty) return;
    if (parent.interactive && parent.label == null && !parent.masked) {
      parent.label = ScruterText.clean(l, 80);
    } else {
      _pendingLabel = l;
    }
  }

  void _takeLabel(TreeNode n) {
    final l = _pendingLabel;
    if (l == null) return;
    _pendingLabel = null;
    n.label = n.masked ? null : ScruterText.clean(l, 80);
  }

  void _leafLabel(Widget w, TreeNode n) {
    String? s;
    if (w is Text) {
      s = w.data ?? w.textSpan?.toPlainText();
    } else if (w is RichText) {
      s = w.text.toPlainText();
    } else if (w is Image) {
      s = w.semanticLabel;
    } else if (w is Icon) {
      s = w.semanticLabel;
    }
    final text = ScruterText.clean(s, 80);
    if (text == null) return;
    n.label ??= text;
    // The nearest interactive ancestor is named by what it shows, within its first levels.
    var a = n.parent;
    for (var i = 0; a != null && a.parent != null && i < 4; i++, a = a.parent) {
      if (a.interactive || a.item != null) {
        a.label ??= text;
        return;
      }
    }
  }

  /// A text input: its [EditableText] is found, and nothing inside it is ever a node.
  void _input(Element e, TreeNode n) {
    n.masked = true;
    n.label = null;
    void down(Element x) {
      if (x is RenderObjectElement) _note(x.renderObject, n);
      final w = x.widget;
      if (w is EditableText) n.editable ??= w;
      x.visitChildren(down);
    }

    final w = e.widget;
    if (w is EditableText) n.editable ??= w;
    e.visitChildren(down);
    n.autofillHints = w is TextField
        ? w.autofillHints
        : w is CupertinoTextField
            ? w.autofillHints
            : n.editable?.autofillHints;
  }

  /// A list or grid item: its part is its first meaningful widget's, its index the item's position.
  void _item(Element child, TreeNode list, {required bool written}) {
    if (child is RenderObjectElement) _note(child.renderObject, list);
    final index = child.slot is int ? child.slot! as int : 0;
    final content = _itemContent(child);
    final w = content.widget;
    final info = _info(w);
    final id = _explicit(w, item: !written);
    final stable = id != null && ScruterText.isStableId(id);
    final role = info?.role ?? _Role.plain;
    final field = role == _Role.input || role == _Role.choice;
    final kind = field || role == _Role.button ? info!.kind : 'cell';
    final part = stable ? '#$id' : (info?.name ?? '${_customName(w) ?? 'View'}${_silent(w) ? '[cell]' : ''}');
    final reacts = role != _Role.plain && role != _Role.media && _reacts(w, role);
    final n = TreeNode(content, list, part, kind, explicit: stable, interactive: reacts, open: info == null, item: index);
    n.form = _form;
    n.choice = info?.choice;
    n.isField = field;
    if (role == _Role.media) {
      n.masked = true;
      n.kind = _mediaKind(w);
    }
    if (_labels) _takeLabel(n);
    nodes.add(n);
    _noteDown(child, content, n);
    if (info?.leaf ?? false) {
      _markHits(content, n);
      if (_labels) _leafLabel(w, n);
      return;
    }
    if (role == _Role.input) {
      _input(content, n);
      return;
    }
    final saved = _absorbing;
    final savedControl = _inControl;
    final savedInteractive = _underInteractive;
    _absorb(w, info);
    if (n.interactive) _underInteractive = true;
    _children(content, n);
    _absorbing = saved;
    _inControl = savedControl;
    _underInteractive = savedInteractive;
  }

  void _noteDown(Element from, Element to, TreeNode n) {
    if (_hit == null) return;
    var x = from;
    for (var i = 0; i < 16 && !identical(x, to); i++) {
      if (x is RenderObjectElement) _note(x.renderObject, n);
      Element? next;
      x.visitChildren((c) => next ??= c);
      if (next == null) return;
      x = next!;
    }
    if (x is RenderObjectElement) _note(x.renderObject, n);
  }

  static bool _silent(Widget w) => w is Padding || w is Container || w is SizedBox || w is Center || w is Align || w is Column || w is Row;

  /// Under a list's delegate, the app's widget comes after Flutter's wrappers.
  static Element _itemContent(Element c) {
    var e = c;
    for (var i = 0; i < 12; i++) {
      final w = e.widget;
      final wrapper = w is KeyedSubtree || w is AutomaticKeepAlive || w is KeepAlive || w is NotificationListener ||
          w is IndexedSemantics || w is RepaintBoundary || w.runtimeType.toString() == '_SelectionKeepAlive';
      if (!wrapper) return e;
      Element? only;
      e.visitChildren((x) => only ??= x);
      if (only == null) return e;
      e = only!;
    }
    return e;
  }

  /// The target of a tap at [hitNode] (§3.5 step 1): the nearest interactive ancestor, else the hit element, climbing
  /// at most 3 levels out of plain text and image wrappers. Nothing inside a masked or ignored element is a target.
  TreeNode? target() {
    final hit = hitNode;
    if (hit == null) return null;
    for (TreeNode? n = hit; n != null; n = n.parent) {
      if (n.masked && n.kind != 'input' || n.ignored) return null;
    }
    for (TreeNode? n = hit; n != null && n.parent != null; n = n.parent) {
      if (n.interactive) return n;
    }
    var n = hit;
    for (var i = 0; i < 3 && n.parent != null && n.parent!.parent != null && n.kind == 'other'; i++) {
      n = n.parent!;
    }
    return n;
  }

  // ------------------------------------------------------------------------------------------------ identity

  /// `(selector, index)` of [target] (§3.5, `IDENTITY_VERSION = 1`).
  (String, int) identify(TreeNode target) {
    // A list or grid item, or an element inside one: the list's part + the item's part, the index is the item's
    // position: every item of the list shares the selector.
    for (TreeNode? n = target; n != null && n.parent != null; n = n.parent) {
      final item = n.item;
      if (item != null) {
        final parts = [n.parent!.part, n.part];
        if (!identical(target, n)) {
          parts.addAll(_context(target, n, _subtree(n)));
        }
        return (_join(parts), item.clamp(0, 9999));
      }
    }
    final population = _subtree(root);
    final parts = _context(target, root, population);
    final own = parts.last;
    final context = parts.reversed.skip(1).toList();
    var index = 0;
    for (final n in population) {
      if (identical(n, target)) break;
      if (n.part != own || n.inItem) continue;
      final c = n.chain();
      var same = c.length >= context.length;
      for (var i = 0; same && i < context.length; i++) {
        same = c[i] == context[i];
      }
      if (same) index++;
    }
    return (_join(parts), index.clamp(0, 9999));
  }

  static List<TreeNode> _subtree(TreeNode root) {
    final out = <TreeNode>[];
    void add(TreeNode n) {
      for (final c in n.children) {
        out.add(c);
        add(c);
      }
    }

    add(root);
    return out;
  }

  /// The parts of [target] below [root] with as much context as needed: while another element has the same selector
  /// and a different parent chain, prefix the nearest ancestor's part (≤ 6 levels); an ancestor with an explicit
  /// identifier ends the climb.
  static List<String> _context(TreeNode target, TreeNode root, List<TreeNode> population) {
    final parts = <String>[target.part];
    final chain = _below(target, root);
    var others = <List<String>>[
      for (final n in population)
        if (!identical(n, target) && n.part == target.part) _below(n, root),
    ]..removeWhere((c) => _same(c, chain));
    var level = 0;
    while (others.isNotEmpty && level < 6 && level < chain.length) {
      final p = chain[level];
      parts.insert(0, p);
      if (p.startsWith('#')) break;
      final l = level;
      others = others.where((c) => l < c.length && c[l] == p).toList();
      level++;
    }
    return parts;
  }

  static List<String> _below(TreeNode n, TreeNode root) {
    final out = <String>[];
    for (var a = n.parent; a != null && !identical(a, root) && a.parent != null; a = a.parent) {
      out.add(a.part);
    }
    return out;
  }

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Joined with `/`, ≤ 200 characters, cut at a `/`: the farthest context goes first.
  static String _join(List<String> parts) {
    var p = parts;
    var s = p.join('/');
    while (s.runes.length > 200 && p.length > 1) {
      p = p.sublist(1);
      s = p.join('/');
    }
    return ScruterText.cut(s, 200);
  }

  /// An in-memory fingerprint of the tree under [root]: types and texts on stage (§3.6: a dead tap changes nothing).
  /// Only compared, never kept or sent.
  static int fingerprint(Element root) {
    var h = 17;
    var count = 0;
    void walk(Element e) {
      final w = e.widget;
      h = (h * 31 + w.runtimeType.hashCode) & 0x3FFFFFFF;
      if (w is Text) h = (h * 31 + w.data.hashCode) & 0x3FFFFFFF;
      count++;
      e.debugVisitOnstageChildren(walk);
    }

    walk(root);
    return h ^ count;
  }
}
