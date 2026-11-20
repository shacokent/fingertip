import 'dart:ui';

/// Shared canonical nail outline for the DIY canvas, thumbnails, and UV mapping.
Path standardNailPath(Size size) => Path()
  ..moveTo(size.width * .12, size.height * .84)
  ..lineTo(size.width * .08, size.height * .29)
  ..cubicTo(
    size.width * .055,
    size.height * .075,
    size.width * .26,
    size.height * .025,
    size.width * .5,
    size.height * .025,
  )
  ..cubicTo(
    size.width * .74,
    size.height * .025,
    size.width * .945,
    size.height * .075,
    size.width * .92,
    size.height * .29,
  )
  ..lineTo(size.width * .88, size.height * .84)
  ..cubicTo(
    size.width * .85,
    size.height * .98,
    size.width * .15,
    size.height * .98,
    size.width * .12,
    size.height * .84,
  )
  ..close();
