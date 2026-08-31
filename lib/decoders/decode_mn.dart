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
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:overmorrow/decoders/decode_OM.dart';
import 'package:overmorrow/services/weather_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/caching_service.dart';

import '../weather_refact.dart';
import 'decode_RV.dart';
import 'weather_data.dart';


String metNTextCorrection(String text) {
  String p = metNWeatherToText[text] ?? 'Clear Sky';
  return p;
}

class MetNTimezoneInfo {
  final DateTime localTime;
  final Duration utcOffset;

  const MetNTimezoneInfo({
    required this.localTime,
    required this.utcOffset,
  });
}

DateTime metNUtcToLocationTime(String timestamp, Duration utcOffset) {
  final DateTime shifted =
      DateTime.parse(timestamp).toUtc().add(utcOffset);

  // Return a wall-clock DateTime whose components represent the forecast
  // location rather than the phone's timezone.
  return DateTime(
    shifted.year,
    shifted.month,
    shifted.day,
    shifted.hour,
    shifted.minute,
    shifted.second,
    shifted.millisecond,
    shifted.microsecond,
  );
}

double metNcalculateFeelsLike(double t, double r, double v) {
  //unfortunately met norway has no feels like temperatures, so i have to calculate it myself based on:
  //temperature, relative humidity, and wind speed
  // https://meteor.geol.iastate.edu/~ckarsten/bufkit/apparent_temperature.html

  if (t >= 24) {
    t = (t * 1.8) + 32;

    double heat_index = -42.379 + (2.04901523 * t) + (10.14333127 * r)
        - (0.22475541 * t * r) - (0.00683783 * t * t)
        - (0.05481717 * r * r) + (0.00122874 * t * t * r)
        + (0.00085282 * t * r * r) - (0.00000199 * t * t * r * r);

    return ((heat_index - 32) / 1.8);
  }

  else if (t <= 13) {
    t = (t * 1.8) + 32;

    double wind_chill = 35.74 + (0.6215 * t) - (35.75 * pow(v, 0.16)) + (0.4275 * t * pow(v, 0.16));

    return ((wind_chill - 32) / 1.8);
  }

  else {
    return t;
  }

}

Future<MetNTimezoneInfo> MetNGetTimezoneInfo(lat, lng) async {
  // MET Locationforecast timestamps are UTC. Resolve the location offset
  // without requiring a separate API key; Open-Meteo already supports the
  // project's coordinate-based timezone=auto flow and returns utc_offset_seconds.
  final params = {
    'latitude': lat.toString(),
    'longitude': lng.toString(),
    'current': 'temperature_2m',
    'forecast_days': '1',
    'timezone': 'auto',
  };
  final url = Uri.https('api.open-meteo.com', 'v1/forecast', params);
  final file = await XCustomCacheManager.fetchData(
    url.toString(),
    '$lat,$lng met-timezone',
    headers: {
      'User-Agent': 'Overmorrow weather (com.marotidev.overmorrow)',
    },
  );
  final response = await file[0].readAsString();
  final body = jsonDecode(response);

  final int offsetSeconds = (body['utc_offset_seconds'] as num).toInt();
  final Duration offset = Duration(seconds: offsetSeconds);
  final DateTime locationNow = DateTime.now().toUtc().add(offset);

  return MetNTimezoneInfo(
    localTime: DateTime(
      locationNow.year,
      locationNow.month,
      locationNow.day,
      locationNow.hour,
      locationNow.minute,
      locationNow.second,
    ),
    utcOffset: offset,
  );
}

Future<List<dynamic>> MetNMakeRequest(double lat, double lng, String real_loc) async {

  final MnParams = {
    "lat" : lat.toString(),
    "lon" : lng.toString(),
    "altitude" : "100",
  };

  final headers = {
    "User-Agent": "Overmorrow weather (com.marotidev.overmorrow)"
  };
  final MnUrl = Uri.https("api.met.no", 'weatherapi/locationforecast/2.0/complete', MnParams);

  var MnFile = await XCustomCacheManager.fetchData(MnUrl.toString(), "$lat,$lng met.no", headers: headers);

  var MnResponse = await MnFile[0].readAsString();
  bool isonline = MnFile[1];

  final MnData = jsonDecode(MnResponse);

  DateTime fetch_datetime = await MnFile[0].lastModified();
  return [MnData, fetch_datetime, isonline];

}

WeatherCurrent metNWeatherCurrentFromJson(item) {
  final List<dynamic> timeseries = item["properties"]["timeseries"];
  final dynamic it = timeseries[0]["data"];
  dynamic nextHours = it["next_1_hours"] ?? it["next_6_hours"] ?? it["next_12_hours"];

  // Tail entries in the forecast window sometimes carry no next_* summary at
  // all (only "instant" data). Fall back to the nearest entry that has one
  // instead of indexing into null.
  if (nextHours == null) {
    for (final entry in timeseries) {
      final dynamic d = entry["data"];
      final dynamic candidate = d["next_1_hours"] ?? d["next_6_hours"] ?? d["next_12_hours"];
      if (candidate != null) {
        nextHours = candidate;
        break;
      }
    }
  }

  final dynamic details = it["instant"]["details"];

  return WeatherCurrent(
    condition: nextHours != null
        ? metNTextCorrection(nextHours["summary"]["symbol_code"])
        : metNTextCorrection('clearsky_day'),
    precipMm: (nextHours?["details"]?["precipitation_amount"] as num?)?.toDouble() ?? 0,
    tempC: (details["air_temperature"] as num).toDouble(),
    humidity: (details["relative_humidity"] as num?)?.round() ?? 0,
    windKmh: ((details["wind_speed"] as num?)?.toDouble() ?? 0) * 3.6,
    uv: (details["ultraviolet_index_clear_sky"] as num?)?.round() ?? 0,
    feelsLikeC: metNcalculateFeelsLike(
      (details["air_temperature"] as num).toDouble(),
      (details["relative_humidity"] as num?)?.toDouble() ?? 0,
      ((details["wind_speed"] as num?)?.toDouble() ?? 0) * 3.6,
    ),
    windDirA: (details["wind_from_direction"] as num?)?.round() ?? 0,
  );
}

WeatherDay metNWeatherDayFromJson(item, start, end, index, Duration utcOffset) {
  List<double> rawTemps = [];
  List<double> windspeeds = [];
  List<int?> winddirs = [];
  List<double> precip = [];

  int? uv;
  int? precipProb;

  List<int> oneSummary = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  const weather_names = ['Clear Night', 'Partly Cloudy', 'Clear Sky', 'Overcast',
    'Haze', 'Rain', 'Sleet', 'Drizzle', 'Thunderstorm', 'Heavy Snow', 'Fog', 'Snow',
    'Heavy Rain', 'Cloudy Night'];

  List<WeatherHour> hours = [];

  for (int n = start; n < end; n++) {
    WeatherHour hour = metNWeatherHourFromJson(
        item["properties"]["timeseries"][n], utcOffset);
    rawTemps.add(hour.tempC);
    windspeeds.add(hour.windKmh);
    winddirs.add(hour.windDirA);

    precip.add(hour.precipMm);

    int index = weather_names.indexOf(hour.condition);
    int value = weatherConditionBiassTable[hour.condition] ?? 0;
    oneSummary[index] += value;

    if ((hour.precipProb ?? 0) > (precipProb ?? 0)) {
      precipProb = hour.precipProb?.toInt();
    }
    if ((hour.uv ?? 0) > (uv ?? 0)) {
      uv = hour.uv?.toInt();
    }

    hours.add(hour);
  }

  int largest_value = oneSummary.reduce(max);
  int BIndex = oneSummary.indexOf(largest_value);

  return WeatherDay(
      totalPrecipMm: precip.reduce((a, b) => a + b),
      precipProb: precipProb,
      minTempC: rawTemps.reduce(min),
      maxTempC:  rawTemps.reduce(max),
      hourly: hours,
      windKmh: (windspeeds.reduce((a, b) => a + b) / windspeeds.length),
      date: metNUtcToLocationTime(
          item["properties"]["timeseries"][start]["time"], utcOffset),
      condition: weather_names[BIndex],
      windDirA: winddirs.whereType<int>().isEmpty
          ? 0
          : (winddirs.whereType<int>().reduce((a, b) => a + b) /
                  winddirs.whereType<int>().length)
              .round(),
      uv: uv,
  );
}

WeatherHour metNWeatherHourFromJson(item, Duration utcOffset) {
  final dynamic nextHours = item["data"]["next_1_hours"] ??
      item["data"]["next_6_hours"] ??
      item["data"]["next_12_hours"];
  final dynamic details = item["data"]["instant"]["details"];

  // Some hours near the end of the forecast window have no next_* summary
  // at all — don't crash, just report a neutral condition for that hour.
  return WeatherHour(
    windGustKmh: null,
    condition: nextHours != null
        ? metNTextCorrection(nextHours["summary"]["symbol_code"])
        : metNTextCorrection('clearsky_day'),
    tempC: (details["air_temperature"] as num).toDouble(),
    precipMm: (nextHours?["details"]?["precipitation_amount"] as num?)?.toDouble() ?? 0,
    precipProb: (nextHours?["details"]?["probability_of_precipitation"] as num?)?.round(),
    time: metNUtcToLocationTime(item["time"], utcOffset),
    windKmh: ((details["wind_speed"] as num?)?.toDouble() ?? 0) * 3.6,
    windDirA: (details["wind_from_direction"] as num?)?.round(),
    uv: (details["ultraviolet_index_clear_sky"] as num?)?.round(),
  );
}

Future<WeatherSunStatus> metNGetWeatherSunStatus(
    lat, lng, Duration utcOffset, DateTime timeThere) async {
  final MnParams = {
    "lat" : lat.toString(),
    "lon" : lng.toString(),
    // Use the forecast location's current date. The cache file's modified date
    // may be stale and may also be in the phone's timezone.
    "date" : "${timeThere.year}-${timeThere.month.toString().padLeft(2, "0")}-${timeThere.day.toString().padLeft(2, "0")}",
  };
  final headers = {
    "User-Agent": "Overmorrow weather (com.marotidev.overmorrow)"
  };
  final MnUrl = Uri.https("api.met.no", 'weatherapi/sunrise/3.0/sun', MnParams);

  var MnFile = await XCustomCacheManager.fetchData(MnUrl.toString(), "$lat, $lng met.no aqi", headers: headers);
  var MnResponse = await MnFile[0].readAsString();
  final item = jsonDecode(MnResponse);

  DateTime sunrise = metNUtcToLocationTime(
      item["properties"]["sunrise"]["time"], utcOffset);
  DateTime sunset = metNUtcToLocationTime(
      item["properties"]["sunset"]["time"], utcOffset);

  return WeatherSunStatus(
    sunrise: sunrise,
    sunset: sunset,
    sunstatus: min(max(timeThere.difference(sunrise).inMinutes / sunset.difference(sunrise).inMinutes, 0), 1),
  );
}

WeatherRain15Minutes metNWeatherRain15MinutesFromJson(item) {
  //met norway doesn't actaully have 15 minute forecast but i figured i could just use the
  //hourly data and just use some smoothing between the hours to emulate the 15 minutes
  //still better than not having it

  int closest = 100;
  int end = -1;
  double sum = 0;

  List<double> precips = [];
  List<double> hourly = [];

  final List<dynamic> timeseries = item["properties"]["timeseries"];
  final int count = min(6, timeseries.length);

  for (int i = 0; i < count; i++) {
    final dynamic data = timeseries[i]["data"];
    final dynamic nextHours =
        data["next_1_hours"] ??
        data["next_6_hours"] ??
        data["next_12_hours"];

    final double x =
        (nextHours?["details"]?["precipitation_amount"] as num?)
                ?.toDouble() ??
            0.0;

    if (x > 0.0) {
      if (closest == 100) {
        closest = i + 1;
      }
      if (i >= end) {
        end = i + 1;
      }
    }

    hourly.add(x);
  }

  //smooth the hours into 15 minute segments

  for (int i = 0; i < hourly.length - 1; i++) {
    double now = hourly[i];
    double next = hourly[i + 1];

    double dif = next - now;
    for (double x = 0; x <= 1; x += 0.25) {
      double g = (now + dif * x) / 4; //because we are dividing the sum of 1 hour into quarters
      sum += g;
      precips.add(g);
    }
  }

  int time = 0;
  String text = "";
  if (closest != 100) {
    if (closest <= 2) {
      if (end <= 1) {
        text = "rainInOneHour";
      }
      else {
        text = "rainInHours";
        time = end;
      }
    }
    else if (closest < 1) {
      text = "rainExpectedInOneHour";
    }
    else {
      text = "rainExpectedInHours";
      time = closest;
    }
  }

  sum = max(sum, 0.1); //if there is rain then it shouldn't write 0

  return WeatherRain15Minutes(
    text: text,
    timeTo: time,
    precipSumMm: sum,
    precipListMm: precips,
  );

}

Future<WeatherData> MetNGetWeatherData(lat, lng, placeName) async {

  var Mn = await MetNMakeRequest(lat, lng, placeName);
  var MnBody = Mn[0];

  final MetNTimezoneInfo timezoneInfo = await MetNGetTimezoneInfo(lat, lng);
  final DateTime localTime = timezoneInfo.localTime;
  final Duration utcOffset = timezoneInfo.utcOffset;
  final DateTime fetch_datetime = Mn[1];
  final bool isonline = Mn[2];

  // timezoneInfo.localTime is already the current wall-clock time at the
  // forecast location. Do not add the cache age to it again. Instead, remove
  // forecast entries whose actual timestamps are before the current hour.
  final DateTime currentHour = DateTime(
    localTime.year,
    localTime.month,
    localTime.day,
    localTime.hour,
  );

  final List<dynamic> timeseries = MnBody["properties"]["timeseries"];
  int start = 0;
  while (start < timeseries.length) {
    final DateTime forecastHour =
        metNUtcToLocationTime(timeseries[start]["time"], utcOffset);
    if (!forecastHour.isBefore(currentHour)) {
      break;
    }
    start += 1;
  }

  if (start >= timeseries.length) {
    throw const SocketException("Cached data expired");
  }

  MnBody["properties"]["timeseries"] = timeseries.sublist(start);

  List<WeatherDay> days = [];
  List<WeatherHour> hourly72 = [];

  int begin = 0;
  int index = 0;

  DateTime? previousTime;
  for (int n = 0; n < MnBody["properties"]["timeseries"].length; n++) {
    final DateTime localForecastTime = metNUtcToLocationTime(
        MnBody["properties"]["timeseries"][n]["time"], utcOffset);
    final bool crossedDateBoundary = previousTime != null &&
        (localForecastTime.year != previousTime.year ||
            localForecastTime.month != previousTime.month ||
            localForecastTime.day != previousTime.day);

    if (n > 0 && crossedDateBoundary) {
      WeatherDay day =
          metNWeatherDayFromJson(MnBody, begin, n, index, utcOffset);
      days.add(day);

      if (hourly72.length < 72) {
        for (int z = 0; z < day.hourly.length; z++) {
          if (hourly72.length < 72) {
            hourly72.add(day.hourly[z]);
          }
        }
      }

      index += 1;
      begin = n;
    }
    previousTime = localForecastTime;
  }

  // The boundary loop adds a day only when it encounters the next date.
  // Flush the final accumulated segment as well so the last forecast day
  // is not silently dropped.
  if (begin < MnBody["properties"]["timeseries"].length) {
    final WeatherDay finalDay = metNWeatherDayFromJson(
      MnBody,
      begin,
      MnBody["properties"]["timeseries"].length,
      index,
      utcOffset,
    );
    days.add(finalDay);
    if (hourly72.length < 72) {
      for (final WeatherHour hour in finalDay.hourly) {
        if (hourly72.length >= 72) break;
        hourly72.add(hour);
      }
    }
  }

  return WeatherData(
    provider: "met norway",

    lat: lat,
    lng: lng,

    place: placeName,

    radar: await RainviewerRadar.getData(),
    aqi: await oMGetWeatherAqi(lat, lng),
    sunStatus: await metNGetWeatherSunStatus(
        lat, lng, utcOffset, localTime),
    alerts: [],
    minutely15Precip: metNWeatherRain15MinutesFromJson(MnBody),

    current: metNWeatherCurrentFromJson(MnBody),
    days: days,

    dailyMinMaxTemp: weatherGetMaxMinTempForDaily(days),

    hourly72: hourly72,

    fetchDatetime: fetch_datetime,
    updatedTime: DateTime.now(),
    localTime: localTime,
    isOnline: isonline,
  );
}

Future<dynamic> metNGetLightResponse(lat, lon, {bool isCompact = true}) async {
  final params = {
    "lat" : lat.toString(),
    "lon" : lon.toString(),
    "altitude" : "100",
  };

  final headers = {
    "User-Agent": "Overmorrow weather (com.marotidev.overmorrow)"
  };
  final url = Uri.https("api.met.no", 'weatherapi/locationforecast/2.0/${isCompact ? "compact" : "complete"}', params);

  final http.Response response = await http.get(url, headers: headers);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException(
      'MET Norway request failed: ${response.statusCode}',
    );
  }

  return jsonDecode(response.body);
}

Future<LightCurrentWeatherData> metNGetLightCurrentData(placeName, lat, lon, SharedPreferences prefs) async {
  final item = await metNGetLightResponse(lat, lon);
  final MetNTimezoneInfo timezoneInfo = await MetNGetTimezoneInfo(lat, lon);
  final DateTime localNow = timezoneInfo.localTime;
  final dynamic first = item["properties"]["timeseries"][0]["data"];
  final dynamic next = first["next_1_hours"] ?? first["next_6_hours"] ?? first["next_12_hours"];

  return LightCurrentWeatherData(
    condition: next != null
        ? metNTextCorrection(next["summary"]["symbol_code"])
        : metNTextCorrection('clearsky_day'),
    place: placeName,
    temp: unitConversion(
      first["instant"]["details"]["air_temperature"],
      prefs.getString("Temperature") ?? "˚C",
    ).round(),
    updatedTime: "${localNow.hour}:${localNow.minute.toString().padLeft(2, "0")}",
    dateString: getDateStringFromLocalTime(localNow),
  );
}

Future<LightWindData> metNGetLightWindData(lat, lon, SharedPreferences prefs) async {
  final item = await metNGetLightResponse(lat, lon);

  return LightWindData(
    windDirAngle: (item["properties"]["timeseries"][0]["data"]["instant"]["details"]["wind_from_direction"] as num?)?.round() ?? 0,
    windSpeed: unitConversion(item["properties"]["timeseries"][0]["data"]["instant"]["details"]["wind_speed"] * 3.6, prefs.getString("Wind") ?? "m/s").round(),
    windUnit: prefs.getString("Wind") ?? "m/s",
  );
}

Future<LightUvData> metNGetLightUvData(lat, lon, SharedPreferences prefs) async {
  final item = await metNGetLightResponse(lat, lon, isCompact: false);

  return LightUvData(
      uv: (item["properties"]["timeseries"][0]["data"]["instant"]["details"]["ultraviolet_index_clear_sky"] as num?)?.round() ?? 0,
  );
}

Future<LightHourlyForecastData> metNGetLightHourlyData(placeName, lat, lon, SharedPreferences prefs) async {
  // Use the complete endpoint so UV is available when MET supplies it.
  final item = await metNGetLightResponse(lat, lon, isCompact: false);
  final MetNTimezoneInfo timezoneInfo = await MetNGetTimezoneInfo(lat, lon);
  final Duration utcOffset = timezoneInfo.utcOffset;
  final DateTime localNow = timezoneInfo.localTime;

  final List<String> hourly6Conditions = [];
  final List<int> hourly6Temps = [];
  final List<String> hourly6Names = [];
  final List<String> hourly1Conditions = [];
  final List<int> hourly1Temps = [];
  final List<String> hourly1Names = [];
  final List<int> hourly1PrecipProbability = [];

  final String tempUnit = prefs.getString("Temperature") ?? "˚C";
  final String timeMode = prefs.getString("Time mode") ?? "12 hour";
  final String windUnit = prefs.getString("Wind") ?? "m/s";

  final DateTime currentHour = DateTime(
    localNow.year,
    localNow.month,
    localNow.day,
    localNow.hour,
  );
  final DateTime forecastEnd = currentHour.add(const Duration(hours: 6));
  final DateTime todayEnd = DateTime(
    localNow.year,
    localNow.month,
    localNow.day,
  ).add(const Duration(days: 1));

  int currentPrecipProbability = 0;
  int currentUv = 0;
  final List<double> todayTempsC = [];

  for (final hour in item["properties"]["timeseries"]) {
    final DateTime d = metNUtcToLocationTime(hour["time"], utcOffset);
    final dynamic data = hour["data"];
    final dynamic details = data["instant"]["details"];
    final dynamic next = data["next_1_hours"] ?? data["next_6_hours"] ?? data["next_12_hours"];
    if (next == null) continue;

    if (d.year == localNow.year &&
        d.month == localNow.month &&
        d.day == localNow.day) {
      todayTempsC.add((details["air_temperature"] as num).toDouble());
    }

    if (d.hour % 6 == 0 && d.isBefore(todayEnd) && !d.isBefore(DateTime(localNow.year, localNow.month, localNow.day))) {
      hourly6Conditions.add(metNTextCorrection(next["summary"]["symbol_code"]));
      hourly6Temps.add(unitConversion(
        (details["air_temperature"] as num).toDouble(),
        tempUnit,
      ).round());
      hourly6Names.add(formatHourByTimeMode(d, timeMode));
    }

    if (!d.isBefore(currentHour) && d.isBefore(forecastEnd)) {
      final int precip = (next["details"]["probability_of_precipitation"] as num?)?.round() ?? 0;
      if (hourly1Conditions.isEmpty) {
        currentPrecipProbability = precip;
        currentUv = (details["ultraviolet_index_clear_sky"] as num?)?.round() ?? 0;
      }

      hourly1Conditions.add(metNTextCorrection(next["summary"]["symbol_code"]));
      hourly1Temps.add(unitConversion(
        (details["air_temperature"] as num).toDouble(),
        tempUnit,
      ).round());
      hourly1Names.add(formatHourByTimeMode(d, timeMode));
      hourly1PrecipProbability.add(precip);
    }

    if (d.isAfter(forecastEnd) && todayTempsC.isNotEmpty) {
      // We already have everything needed for the rolling strip/current day.
      // Do not break before crossing today's end because max/min still needs it.
      if (!d.isBefore(todayEnd)) break;
    }
  }

  final dynamic firstData = item["properties"]["timeseries"][0]["data"];
  final dynamic firstDetails = firstData["instant"]["details"];
  final dynamic firstNext = firstData["next_1_hours"] ?? firstData["next_6_hours"] ?? firstData["next_12_hours"];
  final double currentTempC = (firstDetails["air_temperature"] as num).toDouble();
  final double humidity = (firstDetails["relative_humidity"] as num?)?.toDouble() ?? 0;
  final double windKmh = ((firstDetails["wind_speed"] as num?)?.toDouble() ?? 0) * 3.6;

  final double maxTempC = todayTempsC.isEmpty ? currentTempC : todayTempsC.reduce(max);
  final double minTempC = todayTempsC.isEmpty ? currentTempC : todayTempsC.reduce(min);

  return LightHourlyForecastData(
    place: placeName,
    currentCondition: firstNext != null
        ? metNTextCorrection(firstNext["summary"]["symbol_code"])
        : metNTextCorrection('clearsky_day'),
    currentTemp: unitConversion(currentTempC, tempUnit).round(),
    updatedTime: "${localNow.hour}:${localNow.minute.toString().padLeft(2, "0")}",
    hourly6Conditions: jsonEncode(hourly6Conditions),
    hourly6Names: jsonEncode(hourly6Names),
    hourly6Temps: jsonEncode(hourly6Temps),
    hourly1Conditions: jsonEncode(hourly1Conditions),
    hourly1Names: jsonEncode(hourly1Names),
    hourly1Temps: jsonEncode(hourly1Temps),
    feelsLike: unitConversion(
      metNcalculateFeelsLike(currentTempC, humidity, windKmh),
      tempUnit,
    ).round(),
    tempMax: unitConversion(maxTempC, tempUnit).round(),
    tempMin: unitConversion(minTempC, tempUnit).round(),
    humidity: humidity.round(),
    uvIndex: currentUv,
    windSpeed: unitConversion(windKmh, windUnit).toDouble(),
    windUnit: windUnit,
    precipProbability: currentPrecipProbability,
    hourly1PrecipProbability: jsonEncode(hourly1PrecipProbability),
  );
}

