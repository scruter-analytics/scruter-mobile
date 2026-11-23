import 'package:flutter/widgets.dart';

/// Covers [child] with an opaque rectangle in the team phones' screen images, on the phone, before the image is
/// encoded, and leaves it out of taps (docs/MOBILE.md §3.5, §3.11). Text fields are always masked.
class ScruterMask extends StatelessWidget {
  const ScruterMask({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Leaves [child] out of taps, forms and screen images' element tree (docs/MOBILE.md §3.5).
class ScruterIgnore extends StatelessWidget {
  const ScruterIgnore({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Gives [child] a stable name in Screen analysis (docs/MOBILE.md §3.5): it starts with a letter, holds only
/// `A–Z a–z 0–9 _ . : -`, ≤ 60 characters, and is never generated (no long number, no UUID).
class ScruterId extends StatelessWidget {
  const ScruterId(this.id, {super.key, required this.child});

  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Groups the fields of [child] in a form named [name] (docs/MOBILE.md §3.9), instead of the screen's.
class ScruterForm extends StatelessWidget {
  const ScruterForm(this.name, {super.key, required this.child});

  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
