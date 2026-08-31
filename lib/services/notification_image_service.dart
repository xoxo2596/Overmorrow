/*
Copyright (C) <2026>  <Balint Maroti>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

*/

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';

import '../decoders/weather_data.dart';
import '../weather_refact.dart';

/// Renders the ongoing-notification card (icon, temps, stats row, hourly
/// strip) into a PNG file and returns its path, so it can be shown via
/// BigPictureStyleInformation. Android notifications can't lay out an
/// arbitrary grid like this through the built-in styles, so the whole card
/// is drawn once as a bitmap instead.
class NotificationImageService {

  // The app-open refresh (NotificationService.init) and the 15-min
  // WorkManager background task can both call this around the same time,
  // and WorkManager runs its task in a *separate isolate/engine* from the
  // main app. Doing GPU rasterization (Canvas / Picture.toImage) from two
  // engines at once can crash the GPU driver, and a plain Dart lock
  // (a static field) wouldn't help since isolates don't share memory.
  // An OS-level file lock does work across isolates, so use that to make
  // sure only one build ever runs at a time - a second caller just waits
  // for the file lock instead of rendering concurrently.
  static Future<String> buildOngoingNotificationImage(
      LightHourlyForecastData data) async {
    final Directory tempDirectory = await getTemporaryDirectory();
    final File lockFile = File(
      '${tempDirectory.path}/overmorrow_notification_render.lock',
    );
    final RandomAccessFile lockHandle =
        await lockFile.open(mode: FileMode.append);

    try {
      await lockHandle.lock(FileLock.exclusive);
      return await _buildOngoingNotificationImage(data);
    } finally {
      try {
        await lockHandle.unlock();
      } finally {
        await lockHandle.close();
      }
    }
  }

  static Future<String> _buildOngoingNotificationImage(
      LightHourlyForecastData data) async {
    final bool isDark = SchedulerBinding
            .instance.platformDispatcher.platformBrightness ==
        Brightness.dark;

    final Color textColor = isDark ? Colors.white : const Color(0xFF1B1B1B);
    final Color subTextColor =
        isDark ? Colors.white70 : const Color(0xFF5F6368);
    final Color dividerColor = isDark ? Colors.white24 : Colors.black12;

    const double scale = 2.5; // render at higher density for a crisp bitmap
    const double width = 340 * scale;
    const double height = 170 * scale;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas =
        Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
    final List<ui.Image> sourceImages = [];

    try {
      // ---- header row: icon, "{temp}° - {place}", "Feels like {x}°",
      //      and high/low | precip on the right
      final ui.Image headerIcon = await _loadSvgAsImage(
        weatherIconPathMap[data.currentCondition] ??
            "assets/weather_icons/clear_sky.svg",
        (30 * scale).round(),
      );
      sourceImages.add(headerIcon);
      canvas.drawImage(headerIcon, Offset(0, 2 * scale), Paint());

      _drawText(
        canvas,
        "${data.currentTemp}° - ${data.place}",
        Offset(40 * scale, 0),
        textColor,
        15 * scale,
        FontWeight.w600,
      );

      _drawText(
        canvas,
        "Feels like: ${data.feelsLike}°",
        Offset(40 * scale, 20 * scale),
        subTextColor,
        11.5 * scale,
        FontWeight.normal,
      );

      final String highLow =
          "${data.tempMax}°/${data.tempMin}° | ${data.precipProbability}%";
      final double highLowWidth =
          _measureText(highLow, 11.5 * scale, FontWeight.normal);
      _drawText(
        canvas,
        highLow,
        Offset(width - highLowWidth, 20 * scale),
        subTextColor,
        11.5 * scale,
        FontWeight.normal,
      );

      // ---- stats row: wind / humidity / uv
      final double statsY = 42 * scale;
      _drawStat(canvas, Icons.air, "${data.windSpeed.round()} ${data.windUnit}",
          Offset(0, statsY), textColor, scale);
      _drawStat(canvas, Icons.water_drop_outlined, "${data.humidity}%",
          Offset(115 * scale, statsY), textColor, scale);
      _drawStat(canvas, Icons.wb_sunny_outlined, "${data.uvIndex}",
          Offset(210 * scale, statsY), textColor, scale);

      // ---- divider
      final Paint dividerPaint = Paint()
        ..color = dividerColor
        ..strokeWidth = 1 * scale;
      canvas.drawLine(
          Offset(0, 66 * scale), Offset(width, 66 * scale), dividerPaint);

      // ---- hourly strip
      final List<String> hourNames =
          List<String>.from(jsonDecode(data.hourly1Names));
      final List<int> hourTemps =
          List<int>.from(jsonDecode(data.hourly1Temps));
      final List<String> hourConditions =
          List<String>.from(jsonDecode(data.hourly1Conditions));

      List<int> hourPrecip = [];
      try {
        hourPrecip =
            List<int>.from(jsonDecode(data.hourly1PrecipProbability));
      } catch (_) {
        // older cached data without this field yet - just skip the row
      }

      final int count =
          [hourNames.length, hourTemps.length, hourConditions.length]
              .reduce((a, b) => a < b ? a : b)
              .clamp(0, 6);

      if (count > 0) {
        final double colWidth = width / count;

        for (int i = 0; i < count; i++) {
          final double colCenter = colWidth * i + colWidth / 2;

          _drawCenteredText(canvas, hourNames[i], Offset(colCenter, 76 * scale),
              subTextColor, 10.5 * scale, FontWeight.normal);

          if (i < hourPrecip.length) {
            _drawCenteredText(
                canvas,
                "${hourPrecip[i]}%",
                Offset(colCenter, 90 * scale),
                subTextColor,
                9.5 * scale,
                FontWeight.normal);
          }

          final ui.Image hourIcon = await _loadSvgAsImage(
            weatherIconPathMap[hourConditions[i]] ??
                "assets/weather_icons/clear_sky.svg",
            (24 * scale).round(),
          );
          sourceImages.add(hourIcon);
          canvas.drawImage(
              hourIcon, Offset(colCenter - (12 * scale), 106 * scale), Paint());

          _drawCenteredText(canvas, "${hourTemps[i]}°",
              Offset(colCenter, 134 * scale), textColor, 12 * scale, FontWeight.w600);
        }
      }

      final ui.Picture picture = recorder.endRecording();
      ui.Image? finalImage;
      try {
        finalImage = await picture.toImage(width.round(), height.round());
        final ByteData? pngBytes =
            await finalImage.toByteData(format: ui.ImageByteFormat.png);
        if (pngBytes == null) {
          throw StateError('Could not encode ongoing notification image');
        }

        final Directory dir = await getTemporaryDirectory();
        final File file = File('${dir.path}/ongoing_notification.png');
        await file.writeAsBytes(pngBytes.buffer.asUint8List(), flush: true);
        return file.path;
      } finally {
        finalImage?.dispose();
        picture.dispose();
      }
    } finally {
      // The worker can tear down its Flutter engine immediately after this
      // Future completes. Release every raster image explicitly before that
      // happens instead of leaving GPU/native resources to finalizers.
      for (final ui.Image image in sourceImages) {
        image.dispose();
      }
    }
  }

  static Future<ui.Image> _loadSvgAsImage(String assetPath, int size) async {
    final loader = SvgAssetLoader(assetPath);
    final PictureInfo pictureInfo = await vg.loadPicture(loader, null);
    ui.Picture? scaledPicture;

    try {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);

      final double sourceSize =
          pictureInfo.size.width == 0 ? 1 : pictureInfo.size.width;
      final double scaleFactor = size / sourceSize;

      canvas.scale(scaleFactor);
      canvas.drawPicture(pictureInfo.picture);

      scaledPicture = recorder.endRecording();
      return await scaledPicture.toImage(size, size);
    } finally {
      scaledPicture?.dispose();
      pictureInfo.picture.dispose();
    }
  }

  static void _drawText(Canvas canvas, String text, Offset offset,
      Color color, double fontSize, FontWeight weight) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, offset);
  }

  static void _drawCenteredText(Canvas canvas, String text, Offset center,
      Color color, double fontSize, FontWeight weight) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    tp.layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy));
  }

  static double _measureText(String text, double fontSize, FontWeight weight) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
          text: text, style: TextStyle(fontSize: fontSize, fontWeight: weight)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    return tp.width;
  }

  static void _drawStat(Canvas canvas, IconData icon, String value,
      Offset offset, Color color, double scale) {
    final TextPainter iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 14 * scale,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    iconPainter.layout();
    iconPainter.paint(canvas, offset);

    _drawText(canvas, value, Offset(offset.dx + 18 * scale, offset.dy + 1 * scale),
        color, 11.5 * scale, FontWeight.normal);
  }
}
