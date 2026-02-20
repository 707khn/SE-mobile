import 'package:flutter/material.dart';

import '../utils/dimensions.dart';

class IconButtonDrawer extends StatefulWidget {
  const IconButtonDrawer({Key? key, required this.icon, required this.function})
      : super(key: key);

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
      iconSize: Dimensions.height30,
      icon: widget.icon,
      onPressed: () {
        widget.function();
      },
    );
  }
}
