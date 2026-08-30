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

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:overmorrow/decoders/weather_data.dart';
import 'package:overmorrow/services/notification_image_service.dart';
import 'package:overmorrow/services/preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../weather_refact.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static const androidDetails = AndroidNotificationDetails(
    'basic_channel',
    'Alerts',
    importance: Importance.max,
    priority: Priority.high,
    //icon: "@drawable/icon_info"
  );

  Future<void> init() async {
    // the plugin has to be initialized every launch, regardless of whether
    // the ongoing notification is currently turned on - otherwise show()
    // silently fails the first time the user flips the toggle on, since
    // initialize() would never have run in that session.
    const androidSettings = AndroidInitializationSettings('@drawable/weather_partly_cloudy');
    const settings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final String? payload = response.payload;
        if (payload != null) {
          print('Notification tapped with payload: $payload');
        }
      },
    );

    // if the user had it on from a previous session, re-show it on this launch too
    if (PreferenceUtils.getBool("Ongoing notification", false)) {
      updateOngoingNotification(PreferenceUtils.instance);
    }
  }

  Future<bool> handleNotificationToggle(bool to) async {
    AndroidFlutterLocalNotificationsPlugin? androidFlutterLocalNotificationsPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidFlutterLocalNotificationsPlugin != null) {
      if (to == true) {
        bool? permissionGranted = await androidFlutterLocalNotificationsPlugin.areNotificationsEnabled();
        if (permissionGranted == true) {
          updateOngoingNotification(PreferenceUtils.instance);
          return true;
        }
        else {
          await androidFlutterLocalNotificationsPlugin.requestNotificationsPermission();

          permissionGranted = await androidFlutterLocalNotificationsPlugin.areNotificationsEnabled();
          if (permissionGranted == true) {
            updateOngoingNotification(PreferenceUtils.instance);
            return true;
          }
          return false;
        }
      } else {
        killOngoingNotification();
        return false;
      }
    }
    return false;
  }

  Future<NotificationAppLaunchDetails?> getNotificationLaunchDetails() async {
    final NotificationAppLaunchDetails? launchDetails = await _plugin.getNotificationAppLaunchDetails();
    return launchDetails;
  }

  Future<void> showSimpleNotification() async {
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id: 0,
      title: 'Hello World',
      body: 'message',
      notificationDetails: details,
    );
  }

  Future<void> updateOngoingNotification(SharedPreferences prefs) async {
    String location = prefs.getString("Ongoing place") ?? "unknown";
    String latLon = prefs.getString("Ongoing latLon") ?? "unknown";
    String provider = prefs.getString("Ongoing provider") ?? "open-meteo";

    if (location == "Current Location") {
      location = prefs.getString('LastKnownPositionName') ?? 'unknown';
      latLon = prefs.getString('LastKnownPositionCord') ?? 'unknown';
    }

    if (location != "unknown" && latLon != "unknown") {
      LightHourlyForecastData data = await LightHourlyForecastData
          .getLightForecastData(location, latLon, provider, prefs);

      NotificationService().showOngoingNotification(data, location, latLon);
    }
  }

  void killOngoingNotification() {
    _plugin.cancel(id: 1);
  }

  Future<void> showOngoingNotification(LightHourlyForecastData data, String location, String latLon) async {

    print("SHOWONGOING");

    // draw the whole card (current temp, feels like, high/low, wind/humidity/uv,
    // hourly strip) into a bitmap, since the built-in notification styles can't
    // lay out a custom grid like this on their own.
    final String cardImagePath =
        await NotificationImageService.buildOngoingNotificationImage(data);

    AndroidNotificationDetails androidNotificationDetails = AndroidNotificationDetails(
      'weather_ongoing',
      'Ongoing Weather',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showWhen: false,
      icon: weatherIconResMap[data.currentCondition] ?? "@drawable/weather_partly_cloudy",
      channelShowBadge: false,
      // collapsed view keeps showing current temp/condition + place,
      // expanded view shows the full custom-drawn card
      styleInformation: BigPictureStyleInformation(
        FilePathAndroidBitmap(cardImagePath),
        hideExpandedLargeIcon: true,
        contentTitle: '${data.currentTemp}° ${data.currentCondition}',
        summaryText: data.place,
      ),
    );

    Map<String, String> payloadData = {
      'location': location,
      'latLon' : latLon
    };

    await _plugin.show(
      id: 1,
      title: '${data.currentTemp}° ${data.currentCondition}',
      body: data.place,
      notificationDetails: NotificationDetails(android: androidNotificationDetails,),
      payload: jsonEncode(payloadData),
    );
  }

}
