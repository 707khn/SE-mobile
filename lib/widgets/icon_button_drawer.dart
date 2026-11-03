import 'package:flutter/material.dart';

import '../utils/dimensions.dart';

class IconButtonDrawer extends StatefulWidget {
  const IconButtonDrawer(
      {Key? key, required this.icon, required this.function, this.size})
      : super(key: key);

  /// Размер значка; без него — от экрана (Dimensions).
  final double? size;

  final dynamic icon;
  final Function function;

  @override
  State<IconButtonDrawer> createState() => _IconButtonDrawerState();
}

class _IconButtonDrawerState extends State<IconButtonDrawer> {
  late Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: (widget.size ?? Dimensions.height30),
      // IconButton.iconSize only sizes children that read IconTheme, i.e. an
      // Icon. Every call site passes an Image, which ignores it and grows to
      // fill whatever the parent allows — so bound it here rather than relying
      // on each caller to wrap the row in a fixed height.
      icon: SizedBox(
        width: (widget.size ?? Dimensions.height30),
        height: (widget.size ?? Dimensions.height30),
        child: FittedBox(fit: BoxFit.contain, child: widget.icon),
      ),
      onPressed: () {
        widget.function();
      },
    );
  }
}
