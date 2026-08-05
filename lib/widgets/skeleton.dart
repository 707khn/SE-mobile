import 'package:flutter/material.dart';

import '../utils/dimensions.dart';
import '../utils/app_theme.dart';

/// Grey placeholders shown while a screen loads.
///
/// A spinner says only "wait"; a skeleton shows the shape of what is coming,
/// which reads as faster at the same network speed — and this backend sleeps
/// between requests, so the wait is often long enough to matter.
class Skeleton extends StatefulWidget {
  const Skeleton({
    Key? key,
    required this.height,
    this.width = double.infinity,
    this.radius = 8,
  }) : super(key: key);

  final double height;
  final double width;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      // Pulsing between two greys rather than a sweeping highlight: cheaper to
      // draw, and calmer on a list of twenty rows.
      opacity: Tween<double>(begin: 0.45, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(
          color: context.hairlineColor,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// Repeated card outlines — used where the screen will show a list of rows.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    Key? key,
    this.rows = 6,
    this.hasLeading = false,
    this.padding,
  }) : super(key: key);

  final int rows;

  /// Draws a circle on the left, for lists whose rows carry an avatar or icon.
  final bool hasLeading;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: padding ??
          EdgeInsets.symmetric(
            horizontal: Dimensions.width20,
            vertical: Dimensions.height30 / 3,
          ),
      itemCount: rows,
      physics: const NeverScrollableScrollPhysics(),
      itemBuilder: (_, index) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            if (hasLeading) ...[
              const Skeleton(height: 40, width: 40, radius: 20),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Rows vary in width so the block does not read as a grid.
                  Skeleton(height: 13, width: index.isEven ? 180 : 140),
                  const SizedBox(height: 7),
                  Skeleton(height: 11, width: index.isEven ? 110 : 150),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder for the payslip screen: header, totals card, two sections.
class SkeletonPayslip extends StatelessWidget {
  const SkeletonPayslip({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Skeleton(height: 74, radius: 12),
          SizedBox(height: Dimensions.height30 / 2),
          const Skeleton(height: 130, radius: 16),
          SizedBox(height: Dimensions.height30 / 2),
          const Skeleton(height: 96, radius: 12),
          SizedBox(height: Dimensions.height30 / 2),
          const Skeleton(height: 96, radius: 12),
        ],
      ),
    );
  }
}
