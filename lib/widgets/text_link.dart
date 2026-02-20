import 'package:flutter/material.dart';
import '../../utils/dimensions.dart';
import 'custom_text.dart';


class TextLink extends StatelessWidget {
  const TextLink({Key? key, required this.title, required this.link, required this.icon}) : super(key: key);

  final String title;
  final dynamic link;
  final Icon icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: icon,
      textColor: Theme.of(context).colorScheme.onBackground,
      tileColor: Theme.of(context).scaffoldBackgroundColor,
      onTap:
        link,
      title: SmallText(content: title, fontSize: Dimensions.fontSize14, textAlign: TextAlign.left, )
    );
  }
}
