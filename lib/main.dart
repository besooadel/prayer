import 'dart:async';
import 'package:adhan/adhan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final plugin = FlutterLocalNotificationsPlugin();

const names = ['الفجر', 'الشروق', 'الظهر', 'العصر', 'المغرب', 'العشاء'];
final methods = <String, CalculationMethod>{
  'أم القرى': CalculationMethod.umm_al_qura,
  'رابطة العالم الإسلامي': CalculationMethod.muslim_world_league,
  'الهيئة المصرية': CalculationMethod.egyptian,
  'كراتشي': CalculationMethod.karachi,
};

List<DateTime> prayerTimesFor(Coordinates c, CalculationMethod m, DateTime day) {
  final params = m.getParameters();
  params.madhab = Madhab.shafi;
  final t = PrayerTimes(c, DateComponents.from(day), params);
  return [t.fajr, t.sunrise, t.dhuhr, t.asr, t.maghrib, t.isha]
      .map((e) => e.toLocal())
      .toList();
}

String fmt(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'ص' : 'م'}';
}

String countdown(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  await plugin.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مواقيت الصلاة',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B6B4A)),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Coordinates coords = Coordinates(21.4225, 39.8262);
  String place = 'مكة المكرمة (افتراضي)';
  int methodIdx = 0;
  Set<int> enabled = {0, 2, 3, 4, 5};
  List<DateTime> times = [];
  DateTime now = DateTime.now();
  Timer? timer;

  CalculationMethod get method => methods.values.elementAt(methodIdx);

  @override
  void initState() {
    super.initState();
    init();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => now = DateTime.now());
      if (times.isNotEmpty && times[0].day != now.day) refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    methodIdx = p.getInt('method') ?? 0;
    enabled = (p.getStringList('enabled') ?? ['0', '2', '3', '4', '5'])
        .map(int.parse)
        .toSet();
    final lat = p.getDouble('lat'), lng = p.getDouble('lng');
    if (lat != null && lng != null) {
      coords = Coordinates(lat, lng);
      place = 'آخر موقع محفوظ';
    }
    await refresh();

    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.low));
        coords = Coordinates(pos.latitude, pos.longitude);
        place = 'موقعك الحالي';
        await p.setDouble('lat', pos.latitude);
        await p.setDouble('lng', pos.longitude);
      }
    } catch (_) {}
    await refresh();
  }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() => times = prayerTimesFor(coords, method, DateTime.now()));
    await schedule();
  }

  Future<void> schedule() async {
    await plugin.cancelAll();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'prayer_times',
        'أوقات الصلاة',
        channelDescription: 'تنبيهات دخول وقت الصلاة',
        importance: Importance.max,
        priority: Priority.high,
      ),
    );
    final start = DateTime.now();
    for (var d = 0; d < 7; d++) {
      final day = start.add(Duration(days: d));
      final list = prayerTimesFor(coords, method, day);
      for (var i = 0; i < list.length; i++) {
        if (!enabled.contains(i) || list[i].isBefore(start)) continue;
        await plugin.zonedSchedule(
          d * 10 + i,
          i == 1 ? 'وقت الشروق' : 'حان الآن موعد صلاة ${names[i]}',
          i == 1 ? 'انتهى وقت صلاة الفجر' : 'حيَّ على الصلاة',
          tz.TZDateTime.from(list[i], tz.UTC),
          details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    }
  }

  (String, DateTime) nextPrayer() {
    for (var i = 0; i < times.length; i++) {
      if (times[i].isAfter(now)) return (names[i], times[i]);
    }
    final t = prayerTimesFor(coords, method, now.add(const Duration(days: 1)));
    return (names[0], t[0]);
  }

  Future<void> savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('method', methodIdx);
    await p.setStringList('enabled', enabled.map((e) => '$e').toList());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (times.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final (nextName, nextTime) = nextPrayer();
    return Scaffold(
      appBar: AppBar(title: const Text('مواقيت الصلاة'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: cs.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Text('الصلاة القادمة', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(nextName,
                    style: Theme.of(context)
                        .textTheme
                        .headlineLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
                Text(fmt(nextTime)),
                const SizedBox(height: 12),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(countdown(nextTime.difference(now)),
                      style: Theme.of(context).textTheme.displaySmall),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: Text(place),
            subtitle: const Text('يُحدَّث الموقع عند فتح التطبيق'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<int>(
              value: methodIdx,
              decoration: const InputDecoration(labelText: 'طريقة الحساب'),
              items: [
                for (var i = 0; i < methods.length; i++)
                  DropdownMenuItem(value: i, child: Text(methods.keys.elementAt(i)))
              ],
              onChanged: (v) async {
                if (v == null) return;
                methodIdx = v;
                await savePrefs();
                await refresh();
              },
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < times.length; i++)
            ListTile(
              title: Text(names[i]),
              subtitle: Text(fmt(times[i])),
              trailing: Switch(
                value: enabled.contains(i),
                onChanged: (on) async {
                  setState(() => on ? enabled.add(i) : enabled.remove(i));
                  await savePrefs();
                  await schedule();
                },
              ),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'تُجدَّل التنبيهات لـ 7 أيام قادمة في كل مرة تفتح فيها التطبيق.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
