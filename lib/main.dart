import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:glass_kit/glass_kit.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:animations/animations.dart';
import 'package:sticky_headers/sticky_headers.dart';
import 'package:intl/intl.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as path;
import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';


// ===============================================================
// ГЛОБАЛЬНІ ЗМІННІ ТА КОНФІГУРАЦІЯ
// ===============================================================
final service = FlutterBackgroundService();
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
const String notificationChannelId = 'sync_channel';
const int progressNotificationId = 1;


// ===============================================================
// МОДЕЛІ ТА СЕРВІСИ
// ===============================================================
class GalleryItem {
  final String filename;
  final String type;
  final String thumbnail;
  final DateTime timestamp;

  GalleryItem({required this.filename, required this.type, required this.thumbnail, required this.timestamp});

  factory GalleryItem.fromJson(Map<String, dynamic> json) {
    if (json['timestamp'] == null) throw Exception('Missing timestamp for item: ${json['filename']}');
    final timestampValue = json['timestamp'];
    if (timestampValue is! num) throw Exception('Invalid timestamp type for item: ${json['filename']}');
    return GalleryItem(
      filename: json['filename'],
      type: json['type'],
      thumbnail: json['thumbnail'],
      timestamp: DateTime.fromMillisecondsSinceEpoch((timestampValue * 1000).toInt()),
    );
  }
}


class FileSystemItem {
  final String name;
  final String type; // 'directory' або 'file'
  final int? size;    // Розмір у байтах, null для папок

  FileSystemItem({required this.name, required this.type, this.size});

  factory FileSystemItem.fromJson(Map<String, dynamic> json) {
    return FileSystemItem(
      name: json['name'],
      type: json['type'],
      size: json['size'],
    );
  }
}



class TextViewerScreen extends StatelessWidget {
  final String serverPath;
  final String filename;

  const TextViewerScreen({Key? key, required this.serverPath, required this.filename}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(filename)),
      body: FutureBuilder<String>(
        future: apiService.fetchTextFileContent(serverPath, filename),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Помилка: ${snapshot.error}'));
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Text(snapshot.data ?? ''),
          );
        },
      ),
    );
  }
}

class ApiService {
  late final SharedPreferences _prefs;
  ApiService(this._prefs);
  Future<String> getBaseUrl() async => _prefs.getString('server_ip') ?? '';

  Future<List<GalleryItem>> fetchGalleryItems() async {
    final baseUrl = await getBaseUrl();
    if (baseUrl.isEmpty) {
        // Повертаємо пустий список, якщо IP не налаштований, щоб не показувати помилку
        // а показати інформативне повідомлення в UI.
        throw Exception('IP адреса сервера не налаштована.');
    }
    try {
      final response = await http.get(Uri.parse('$baseUrl/gallery/')).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        final List<GalleryItem> validItems = [];
        for (var itemJson in data) {
          try {
            validItems.add(GalleryItem.fromJson(itemJson));
          } catch (e) {
            print('Skipping invalid item: $e');
          }
        }
        return validItems;
      } else {
        throw Exception('Failed to load gallery (status code: ${response.statusCode})');
      }
    } catch (e) {
      throw Exception('Помилка мережі або сервер недоступний: $e');
    }
  }
  Future<List<FileSystemItem>> fetchFileSystemItems(String path) async {
    final baseUrl = await getBaseUrl();
    if (baseUrl.isEmpty) {
      throw Exception('IP адреса сервера не налаштована.');
    }
    // Кодуємо шлях, щоб пробіли та інші символи правильно передавались
    final encodedPath = Uri.encodeComponent(path);
    final url = Uri.parse('$baseUrl/files/list/?path=$encodedPath');
    
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final List<dynamic> items = data['items'];
        return items.map((itemJson) => FileSystemItem.fromJson(itemJson)).toList();
      } else {
        throw Exception('Failed to load file list (status code: ${response.statusCode})');
      }
    } catch (e) {
      throw Exception('Помилка мережі при завантаженні файлів: $e');
    }
  }

Future<void> createFolder(String currentPath, String folderName) async {
    final baseUrl = await getBaseUrl();
    if (baseUrl.isEmpty) throw Exception('IP не налаштовано');
    final url = Uri.parse('$baseUrl/files/create_folder/');
    try {
      final response = await http.post(
        url,
        body: {'path': currentPath, 'folder_name': folderName},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        final error = json.decode(response.body)['detail'];
        throw Exception('Помилка створення папки: $error');
      }
    } catch (e) {
      throw Exception('Помилка мережі: $e');
    }
  }

  // <--- НОВИЙ МЕТОД
  Future<void> uploadFile(String localPath, String serverPath, {required Function(int, int) onProgress}) async {
    final baseUrl = await getBaseUrl();
    if (baseUrl.isEmpty) throw Exception('IP не налаштовано');
    
    final dio = Dio();
    final filename = path.basename(localPath);

    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(localPath, filename: filename),
      'path': serverPath,
    });

    try {
      await dio.post(
        '$baseUrl/files/upload_to_path/',
        data: formData,
        onSendProgress: onProgress,
      );
    } on DioException catch (e) {
      throw Exception('Помилка завантаження файлу: ${e.message}');
    }
  }

  // <--- НОВИЙ МЕТОД
  Future<String> downloadFile(String serverPath, String filename, {required Function(int, int) onProgress}) async {
    final baseUrl = await getBaseUrl();
    if (baseUrl.isEmpty) throw Exception('IP не налаштовано');
    
    final dio = Dio();
    // Використовуємо path_provider, щоб знайти папку завантажень
    final dir = await getApplicationDocumentsDirectory(); // або getDownloadsDirectory() для Android
    final localPath = path.join(dir.path, filename);

    final fileUrl = '$baseUrl/original/${path.join(serverPath, filename)}';

    try {
      await dio.download(
        fileUrl,
        localPath,
        onReceiveProgress: onProgress,
      );
      return localPath; // Повертаємо шлях до завантаженого файлу
    } on DioException catch (e) {
      throw Exception('Помилка завантаження файлу: ${e.message}');
    }
  }

  // <--- НОВИЙ МЕТОД
  Future<String> fetchTextFileContent(String serverPath, String filename) async {
     final baseUrl = await getBaseUrl();
     if (baseUrl.isEmpty) throw Exception('IP не налаштовано');
     final fileUrl = '$baseUrl/original/${path.join(serverPath, filename)}';
     
     final response = await http.get(Uri.parse(fileUrl));
     if(response.statusCode == 200) {
       return utf8.decode(response.bodyBytes);
     } else {
       throw Exception('Не вдалося завантажити файл');
     }
  }
}




late ApiService apiService;


// ===============================================================
// ФОНОВИЙ СЕРВІС
// ===============================================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final dio = Dio();
  String? serverIp;
  List<String> syncFolders = [];
  Timer? periodicTimer;
  bool _shouldStopSync = false; // <--- Додаємо прапорець

  service.on('updateSettings').listen((event) {
    serverIp = event?['server_ip'];
    if (event?['sync_folders'] != null) {
      syncFolders = List<String>.from(event?['sync_folders']);
    }
  });

  service.on('startPeriodicSync').listen((event) {
    _shouldStopSync = false; // <--- Скидаємо прапорець при старті
    periodicTimer?.cancel();
    periodicTimer = Timer.periodic(const Duration(minutes: 15), (timer) async {
      if (serverIp != null && syncFolders.isNotEmpty) {
        await _runSync(service, dio, serverIp!, syncFolders, () => _shouldStopSync);
      }
    });
  });

  service.on('runImmediateSync').listen((event) async {
    _shouldStopSync = false; // <--- Скидаємо прапорець при ручному запуску
    if (serverIp != null && syncFolders.isNotEmpty) {
      await _runSync(service, dio, serverIp!, syncFolders, () => _shouldStopSync);
    }
  });

  service.on('stopPeriodicSync').listen((event) {
    _shouldStopSync = true; // <--- Встановлюємо прапорець
    periodicTimer?.cancel();
    flutterLocalNotificationsPlugin.cancel(progressNotificationId);
  });
}

// ОНОВЛЕНИЙ _runSync:
Future<void> _runSync(
  ServiceInstance service,
  Dio dio,
  String serverIp,
  List<String> folderPaths,
  bool Function() shouldStop,
) async {
  service.invoke('syncStateChanged', {'isSyncing': true});
  try {
    if (shouldStop()) return; // <--- Перевірка на початку

    List<String> serverFiles = [];
    try {
      final response = await http.get(Uri.parse('$serverIp/gallery/'));
      if (response.statusCode == 200) {
        serverFiles = (json.decode(utf8.decode(response.bodyBytes)) as List)
            .map((item) => item['filename'] as String).toList();
      }
    } catch (e) { /* ignore */ }

    final filesToUpload = <File>[];
    for (final folderPath in folderPaths) {
      if (shouldStop()) return; // <--- Перевірка перед кожною папкою
      final directory = Directory(folderPath);
      if (!await directory.exists()) continue;
      await for (final entity in directory.list()) {
        if (shouldStop()) return; // <--- Перевірка перед кожним файлом
        if (entity is File) {
          final filename = path.basename(entity.path);
          final extension = path.extension(filename).toLowerCase();
          if (['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.mov', '.avi'].contains(extension)) {
            if (!serverFiles.contains(filename)) {
              filesToUpload.add(entity);
            }
          }
        }
      }
    }

    if (filesToUpload.isEmpty) return;

    int totalFiles = filesToUpload.length;
    for (int i = 0; i < totalFiles; i++) {
      if (shouldStop()) return; // <--- Перевірка перед кожним файлом
      final file = filesToUpload[i];
      final filename = path.basename(file.path);
      try {
        final formData = FormData.fromMap({ 'file': await MultipartFile.fromFile(file.path, filename: filename) });
        await dio.post(
          '$serverIp/upload/',
          data: formData,
          onSendProgress: (int sent, int total) => _showProgressNotification(
            title: 'Синхронізація (${i + 1}/$totalFiles)', body: 'Завантаження: $filename', progress: sent, maxProgress: total
          ),
          options: Options(receiveTimeout: const Duration(minutes: 10)),
        );
      } catch (e) { /* ignore */ }
    }
    await flutterLocalNotificationsPlugin.cancel(progressNotificationId);
    _showCompletionNotification(totalFiles);
  } finally {
    service.invoke('syncStateChanged', {'isSyncing': false});
  }
}

// ===============================================================
// СПОВІЩЕННЯ ТА ІНІЦІАЛІЗАЦІЯ
// ===============================================================
Future<void> _configureNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);
}

Future<void> _showProgressNotification({required String title, required String body, required int progress, required int maxProgress}) async {
  final AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    notificationChannelId, 'Sync Progress',
    channelDescription: 'Shows file synchronization progress', channelShowBadge: false, 
    importance: Importance.low, priority: Priority.low, onlyAlertOnce: true, 
    showProgress: true, maxProgress: maxProgress, progress: progress,
    color: Colors.deepPurple, colorized: true,
  );
  final NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
  await flutterLocalNotificationsPlugin.show(progressNotificationId, title, body, platformChannelSpecifics);
}

Future<void> _showCompletionNotification(int uploadedCount) async {
  final AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    notificationChannelId, 'Sync Progress',
    channelDescription: 'Shows file synchronization progress',
    importance: Importance.defaultImportance, priority: Priority.defaultPriority,
  );
  final NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
  await flutterLocalNotificationsPlugin.show(progressNotificationId + 1, 'Синхронізацію завершено', 'Завантажено $uploadedCount нових файлів.', platformChannelSpecifics);
}

Future<void> initializeService() async {
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart, isForegroundMode: true, autoStart: true,
      notificationChannelId: 'my_app_sync_channel', initialNotificationTitle: 'My Cloud Sync',
      initialNotificationContent: 'Сервіс активний у фоні', foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

String formatDateHeader(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  if (date.isAtSameMomentAs(today)) return 'Сьогодні';
  if (date.isAtSameMomentAs(yesterday)) return 'Вчора';
  return DateFormat.yMMMMd('uk_UA').format(date);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('uk_UA', null); 
  await _configureNotifications(); 
  await initializeService();

  final prefs = await SharedPreferences.getInstance();
  apiService = ApiService(prefs);
  runApp(const MyApp());
}

// ===============================================================
// UI: ВІДЖЕТИ ДОДАТКУ
// ===============================================================

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My Cloud',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple, brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> widgetOptions = <Widget>[
      GalleryScreen(key: const ValueKey('gallery_page')),
      const FilesScreen(key: ValueKey('files_page')), // <--- Замінюємо заглушку
      SettingsScreen(key: const ValueKey('settings_page')),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: PreferredSize(
        preferredSize: const Size(double.infinity, 56.0),
        child: GlassContainer(
          height: 120, width: double.infinity, blur: 10,
          color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
          borderColor: Colors.transparent,
          child: SafeArea(
            child: Center(child: Text('My Personal Cloud', style: Theme.of(context).textTheme.titleLarge))
          )
        )
      ),
      body: PageTransitionSwitcher(
        duration: const Duration(milliseconds: 400),
        transitionBuilder: (child, primaryAnimation, secondaryAnimation) => SharedAxisTransition(
          animation: primaryAnimation,
          secondaryAnimation: secondaryAnimation,
          transitionType: SharedAxisTransitionType.horizontal,
          child: child
        ),
        child: widgetOptions[_selectedIndex]
      ),
      bottomNavigationBar: GlassContainer(
        height: 80, width: double.infinity, blur: 10,
        color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
        borderColor: Colors.transparent,
        child: NavigationBar(
          backgroundColor: Colors.transparent,
          indicatorColor: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onItemTapped,
          destinations: const <NavigationDestination>[
            NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Галерея'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Файли'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Налаштування'),
          ]
        )
      ),
    );
  }
}

// <--- ТУТ ПОЧИНАЄТЬСЯ ВИПРАВЛЕНИЙ КЛАС
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({Key? key}) : super(key: key);
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> with SingleTickerProviderStateMixin { // <--- 1. Додай 'with SingleTickerProviderStateMixin'
  late Future<List<GalleryItem>> _galleryItemsFuture;
  
  // <--- 2. Додай AnimationController та анімацію для блюру
  late final AnimationController _blurAnimationController;
  late final Animation<double> _blurAnimation;
  
  @override
  void initState() {
    super.initState();
    _refreshGallery();
    
    // <--- 3. Ініціалізуй контролер та анімацію
    _blurAnimationController = AnimationController(
      duration: const Duration(milliseconds: 500), // Та сама тривалість, що й у OpenContainer
      vsync: this,
    );
    // Створюємо анімацію, яка змінюється від 0.0 до 1.0
    _blurAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _blurAnimationController,
        curve: Curves.fastOutSlowIn, // Крива для плавного ефекту
      ),
    );
  }

  // <--- 4. Не забудь видалити контролер
  @override
  void dispose() {
    _blurAnimationController.dispose();
    super.dispose();
  }
  
  Future<void> _loadGalleryItems() async {
    final future = apiService.fetchGalleryItems();
    if (mounted) {
      setState(() {
        _galleryItemsFuture = future;
      });
    }
  }

  Future<void> _refreshGallery() async {
    await _loadGalleryItems();
  }

  Map<DateTime, List<GalleryItem>> _groupItemsByDate(List<GalleryItem> items) {
    final Map<DateTime, List<GalleryItem>> groupedItems = {};
    for (var item in items) {
      final dateKey = DateTime(item.timestamp.year, item.timestamp.month, item.timestamp.day);
      if (groupedItems[dateKey] == null) groupedItems[dateKey] = [];
      groupedItems[dateKey]!.add(item);
    }
    return groupedItems;
  }

  // В _GalleryScreenState
// В _GalleryScreenState

// В _GalleryScreenState

@override
Widget build(BuildContext context) {
  return FutureBuilder<List<GalleryItem>>(
    future: _galleryItemsFuture,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text('Помилка: ${snapshot.error}', textAlign: TextAlign.center)));
      if (!snapshot.hasData || snapshot.data!.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [ const Text('Ваша галерея порожня'), const SizedBox(height: 10), ElevatedButton.icon(onPressed: _refreshGallery, icon: const Icon(Icons.refresh), label: const Text('Оновити'))]));
      
      final groupedItems = _groupItemsByDate(snapshot.data!);
      final sortedDates = groupedItems.keys.toList()..sort((a, b) => b.compareTo(a));

      return Stack(
        children: [
          RefreshIndicator(
            onRefresh: () async { _refreshGallery(); },
            child: ListView.builder(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 60, bottom: MediaQuery.of(context).padding.bottom + 90),
              itemCount: sortedDates.length,
              itemBuilder: (context, index) {
                final date = sortedDates[index];
                final itemsForDate = groupedItems[date]!;

                return StickyHeader(
                  header: Container(
                    height: 50.0,
                    color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.95),
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    alignment: Alignment.centerLeft,
                    child: Text(formatDateHeader(date), style: Theme.of(context).textTheme.titleLarge),
                  ),
                  content: GridView.builder(
                    padding: const EdgeInsets.all(4.0),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: itemsForDate.length,
                    itemBuilder: (context, gridIndex) {
                      final item = itemsForDate[gridIndex];
                      
                      return OpenContainer(
                        transitionDuration: const Duration(milliseconds: 500),
                        transitionType: ContainerTransitionType.fade,
                        closedColor: Colors.transparent,
                        openColor: Colors.black,
                        middleColor: Colors.black,
                        closedElevation: 0,
                        openElevation: 0,
                        tappable: false,
                        
                        openBuilder: (BuildContext context, VoidCallback _) {
                          return MediaViewerScreen(
                            galleryItems: snapshot.data!,
                            initialIndex: snapshot.data!.indexOf(item),
                          );
                        },
                        closedBuilder: (BuildContext context, VoidCallback openContainer) {
                          return GestureDetector(
                            onTap: () {
                              _blurAnimationController.forward();
                              openContainer();
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8.0),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  FutureBuilder<String>(
                                    future: apiService.getBaseUrl(),
                                    builder: (context, urlSnapshot) {
                                      if (!urlSnapshot.hasData || urlSnapshot.data!.isEmpty) return const SizedBox.shrink();
                                      final thumbnailUrl = '${urlSnapshot.data}/thumbnail/${item.thumbnail}';
                                      return CachedNetworkImage(
                                        imageUrl: thumbnailUrl,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => Container(color: Colors.grey.withOpacity(0.1)),
                                        errorWidget: (context, url, error) => const Icon(Icons.error),
                                      );
                                    },
                                  ),
                                  if (item.type == 'video')
                                    Center(
                                      child: Container(
                                        decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                                        child: const Icon(Icons.play_arrow, color: Colors.white, size: 24),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                        onClosed: (_) {
                          _blurAnimationController.reverse();
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
          
          AnimatedBuilder(
            animation: _blurAnimation,
            builder: (context, child) {
              if (_blurAnimation.value == 0.0) {
                return const SizedBox.shrink();
              }
              return IgnorePointer(
                ignoring: _blurAnimationController.status == AnimationStatus.reverse,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _blurAnimation.value * 5,
                    sigmaY: _blurAnimation.value * 5,
                  ),
                  child: Container(
                    color: Colors.black.withOpacity(_blurAnimation.value * 0.4),
                  ),
                ),
              );
            },
          ),
        ],
      );
    },
  );
}
}
// <--- ТУТ ЗАКІНЧУЄТЬСЯ ВИПРАВЛЕНИЙ КЛАС
class MediaViewerScreen extends StatefulWidget {
  final List<GalleryItem> galleryItems;
  final int initialIndex;
  const MediaViewerScreen({super.key, required this.galleryItems, required this.initialIndex});
  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}
class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _pageController;
  final StreamController<int> _pageStreamController = StreamController<int>.broadcast();
  // Додаємо контролер для PhotoView
  final PhotoViewController _photoViewController = PhotoViewController();
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(() {
      if (_pageController.page?.round() != null) {
        _pageStreamController.add(_pageController.page!.round());
      }
    });
    _photoViewController.outputStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _currentScale = state.scale ?? 1.0;
        });
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _pageStreamController.close();
    _photoViewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: FutureBuilder<String>(
        future: apiService.getBaseUrl(),
        builder: (context, urlSnapshot) {
          if (!urlSnapshot.hasData) return const Center(child: CircularProgressIndicator());
          final baseUrl = urlSnapshot.data!;
          // ...existing code...
return PageView.builder(
  controller: _pageController,
  physics: _currentScale == 1.0
      ? const PageScrollPhysics()
      : const NeverScrollableScrollPhysics(),
  itemCount: widget.galleryItems.length,
  itemBuilder: (context, index) {
    final item = widget.galleryItems[index];
    final fileUrl = '$baseUrl/original_resized/${item.filename}';
    final thumbUrl = '$baseUrl/thumbnail/${item.thumbnail}';

    if (item.type == 'image') {
  return _FullScreenImageWithFadePhotoView(
    thumbnailUrl: thumbUrl,
    fullImageUrl: fileUrl,
    photoViewController: _photoViewController,
    heroTag: item.filename, // Додаємо heroTag
  );
} else if (item.type == 'video') {
      return MediaPageWidget(
        item: item,
        fileUrl: fileUrl,
        pageStream: _pageStreamController.stream,
        pageIndex: index,
        isCurrentPage: index == widget.initialIndex,
      );
    } else {
      return const Center(child: Text('Невідомий тип файлу', style: TextStyle(color: Colors.white)));
    }
  }
);
        },
      ),
    );
  }
}
// ===============================================================
class _FullScreenImageWithFadePhotoView extends StatefulWidget {
  final String thumbnailUrl;
  final String fullImageUrl;
  final String? heroTag;

  const _FullScreenImageWithFadePhotoView({
    required this.thumbnailUrl,
    required this.fullImageUrl,
    this.heroTag, required PhotoViewController photoViewController,
  });

  @override
  State<_FullScreenImageWithFadePhotoView> createState() => _FullScreenImageWithFadePhotoViewState();
}

class _FullScreenImageWithFadePhotoViewState extends State<_FullScreenImageWithFadePhotoView> with SingleTickerProviderStateMixin {
  bool _fullLoaded = false;
  bool _showThumb = true;
  ImageProvider? _fullImageProvider;
  late final PhotoViewController _photoViewController;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _photoViewController = PhotoViewController();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _photoViewController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  void _onFullLoaded(ImageProvider imageProvider) {
    if (!_fullLoaded) {
      setState(() {
        _fullLoaded = true;
        _fullImageProvider = imageProvider;
      });
      _fadeController.forward().then((_) {
        // Після завершення fade — прибираємо мініатюруhdfghdfghdfghdfghhfdghffd
        setState(() {
          _showThumb = false;
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget imageStack = Stack(
      fit: StackFit.expand,
      children: [
        // 1. Мініатюра під повним фото тільки поки _showThumb == true
        if (_showThumb)
          CachedNetworkImage(
            imageUrl: widget.thumbnailUrl,
            fit: BoxFit.contain,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
          ),
        // 2. Повне фото з fade transition
        if (_fullImageProvider == null)
          CachedNetworkImage(
            imageUrl: widget.fullImageUrl,
            fit: BoxFit.contain,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            imageBuilder: (context, imageProvider) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _onFullLoaded(imageProvider);
              });
              return const SizedBox.shrink();
            },
          )
        else
          FadeTransition(
            opacity: _fadeAnimation,
            child: PhotoView(
              imageProvider: _fullImageProvider!,
              controller: _photoViewController,
              backgroundDecoration: const BoxDecoration(color: Colors.transparent),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4.0,
            ),
          ),
      ],
    );

    if (widget.heroTag != null) {
      return Hero(
        tag: widget.heroTag!,
        child: imageStack,
      );
    } else {
      return imageStack;
    }
  }
}
class MediaPageWidget extends StatefulWidget {
  final GalleryItem item;
  final String fileUrl;
  final Stream<int> pageStream;
  final int pageIndex;
  final bool isCurrentPage;
  const MediaPageWidget({Key? key, required this.item, required this.fileUrl, required this.pageStream, required this.pageIndex, required this.isCurrentPage}) : super(key: key);
  @override
  State<MediaPageWidget> createState() => _MediaPageWidgetState();
}

class _MediaPageWidgetState extends State<MediaPageWidget> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  StreamSubscription? _pageSubscription;
  bool _isDisposed = false;
  bool _isVideoPlayerInitialized = false;

  @override
  void initState() {
    super.initState();
    _pageSubscription = widget.pageStream.listen((currentPageIndex) {
      if (_isDisposed) return;
      if (currentPageIndex != widget.pageIndex) _videoController?.pause();
    });
    if (widget.item.type == 'video') _initializeVideoPlayer();
  }

  Future<void> _initializeVideoPlayer() async {
    _videoController = VideoPlayerController.networkUrl(Uri.parse(widget.fileUrl));
    await _videoController!.initialize();
    if (_isDisposed) return;
    _createChewieController();
    if (mounted) {
      setState(() => _isVideoPlayerInitialized = true);
      if(widget.isCurrentPage) _videoController?.play();
    }
  }

  void _createChewieController() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    _chewieController = ChewieController(
      videoPlayerController: _videoController!,
      aspectRatio: _videoController!.value.aspectRatio,
      autoInitialize: true,
      looping: false,
      materialProgressColors: ChewieProgressColors(
        playedColor: Theme.of(context).colorScheme.primary,
        handleColor: Theme.of(context).colorScheme.primary,
        bufferedColor: Colors.grey.shade600,
        backgroundColor: Colors.grey.shade800,
      ),
      errorBuilder: (context, errorMessage) => Center(child: Text(errorMessage, style: const TextStyle(color: Colors.white)))
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_videoController != null && _videoController!.value.isInitialized && _chewieController == null) {
      _createChewieController();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pageSubscription?.cancel();
    _videoController?.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.type == 'image') {
      return Hero(
        tag: widget.item.filename,
        child: _FullScreenImageWithFade(
          thumbnailUrl: () async {
            final baseUrl = await apiService.getBaseUrl();
            return '$baseUrl/thumbnail/${widget.item.thumbnail}';
          },
          fullImageUrl: widget.fileUrl,
        ),
      );
    } else if (widget.item.type == 'video') {
      return Hero(
        tag: widget.item.filename,
        child: _isVideoPlayerInitialized && _chewieController != null
            ? Chewie(controller: _chewieController!)
            : const Center(child: CircularProgressIndicator(color: Colors.white))
      );
    }
    return const Center(child: Text('Невідомий тип файлу'));
  }
}

class _FullScreenImageWithFade extends StatefulWidget {
  final Future<String> Function() thumbnailUrl;
  final String fullImageUrl;
  const _FullScreenImageWithFade({required this.thumbnailUrl, required this.fullImageUrl});

  @override
  State<_FullScreenImageWithFade> createState() => _FullScreenImageWithFadeState();
}

class _FullScreenImageWithFadeState extends State<_FullScreenImageWithFade> {
  late Future<String> _thumbUrlFuture;
  bool _fullLoaded = false;

  @override
  void initState() {
    super.initState();
    _thumbUrlFuture = widget.thumbnailUrl();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _thumbUrlFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final thumbUrl = snapshot.data!;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. Мініатюра на весь екран
            CachedNetworkImage(
              imageUrl: thumbUrl,
              fit: BoxFit.contain,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
            ),
            // 2. Повне фото з fade transition
            AnimatedOpacity(
              opacity: _fullLoaded ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
              child: CachedNetworkImage(
                imageUrl: widget.fullImageUrl,
                fit: BoxFit.contain,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholder: (context, url) => const SizedBox.shrink(),
                errorWidget: (context, url, error) => const SizedBox.shrink(),
                imageBuilder: (context, imageProvider) {
                  // Коли повне фото завантажилось — показуємо його з fade
                  if (!_fullLoaded) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _fullLoaded = true);
                    });
                  }
                  return Image(
                    image: imageProvider,
                    fit: BoxFit.contain,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
class FilesScreen extends StatefulWidget {
  const FilesScreen({Key? key}) : super(key: key);

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  List<String> _pathStack = [''];
  Map<String, Future<List<FileSystemItem>>> _futureCache = {};
  
  // Для відстеження завантажень
  String? _currentlyUploading;
  double _uploadProgress = 0.0;
  String? _currentlyDownloading;
  double _downloadProgress = 0.0;

  String get _currentPath => _pathStack.last;

  @override
  void initState() {
    super.initState();
    _fetchCurrentPath(forceRefresh: true);
  }

  void _fetchCurrentPath({bool forceRefresh = false}) {
    if (forceRefresh) {
      _futureCache.remove(_currentPath);
    }
    if (!_futureCache.containsKey(_currentPath)) {
      setState(() {
         _futureCache[_currentPath] = apiService.fetchFileSystemItems(_currentPath);
      });
    }
  }

  void _navigateTo(String directoryName) {
    setState(() {
      final newPath = path.join(_currentPath, directoryName);
      _pathStack.add(newPath);
      _fetchCurrentPath();
    });
  }

  Future<bool> _onWillPop() async {
    if (_pathStack.length > 1) {
      setState(() {
        _pathStack.removeLast();
      });
      return false;
    }
    return true;
  }
  
  // === НОВІ ФУНКЦІЇ ===

  void _showCreateFolderDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Створити нову папку'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Назва папки'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
          TextButton(
            onPressed: () async {
              if (controller.text.trim().isEmpty) return;
              Navigator.pop(context);
              try {
                await apiService.createFolder(_currentPath, controller.text.trim());
                _fetchCurrentPath(forceRefresh: true);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
              }
            },
            child: const Text('Створити'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    
    for (final file in result.files) {
      if (file.path == null) continue;
      setState(() {
        _currentlyUploading = file.name;
        _uploadProgress = 0;
      });
      try {
        await apiService.uploadFile(
          file.path!,
          _currentPath,
          onProgress: (sent, total) {
            setState(() {
              _uploadProgress = sent / total;
            });
          },
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Помилка: $e'), backgroundColor: Colors.red));
      } finally {
        setState(() {
          _currentlyUploading = null;
        });
      }
    }
    _fetchCurrentPath(forceRefresh: true);
  }

  Future<void> _handleFileTap(FileSystemItem item) async {
    final ext = path.extension(item.name).toLowerCase();
    
    // Перегляд медіа
    if (['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.mov'].contains(ext)) {
      // Імітуємо GalleryItem для переглядача
      final galleryItem = GalleryItem(
        filename: path.join(_currentPath, item.name),
        type: ['.mp4', '.mov'].contains(ext) ? 'video' : 'image',
        thumbnail: '', // не потрібен для прямого перегляду
        timestamp: DateTime.now(),
      );
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => MediaViewerScreen(galleryItems: [galleryItem], initialIndex: 0)
      ));
      return;
    }
    
    // Перегляд тексту
    if (['.txt', '.md', '.json', '.yaml', '.log'].contains(ext)) {
       Navigator.push(context, MaterialPageRoute(
        builder: (_) => TextViewerScreen(serverPath: _currentPath, filename: item.name)
      ));
      return;
    }

    // Завантаження інших файлів
    setState(() {
      _currentlyDownloading = item.name;
      _downloadProgress = 0;
    });
    try {
      final localPath = await apiService.downloadFile(_currentPath, item.name, onProgress: (rec, total) {
        setState(() {
          _downloadProgress = rec / total;
        });
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Файл "${item.name}" завантажено.'),
          action: SnackBarAction(label: 'ВІДКРИТИ', onPressed: () => OpenFilex.open(localPath)),
        )
      );
    } catch (e) {
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Помилка завантаження: $e'), backgroundColor: Colors.red));
    } finally {
      setState(() => _currentlyDownloading = null);
    }
  }
  
  // === Існуючі функції-хелпери (без змін) ===
   String _formatBytes(int bytes, int decimals) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return ((bytes / pow(1024, i)).toStringAsFixed(decimals)) + ' ' + suffixes[i];
  }
  IconData _getIconForFile(String filename) {
    final extension = path.extension(filename).toLowerCase();
    switch (extension) {
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.bmp':
        return Icons.image_outlined;
      case '.mp4':
      case '.mov':
      case '.avi':
        return Icons.movie_outlined;
      case '.mp3':
      case '.wav':
      case '.aac':
        return Icons.audiotrack_outlined;
      case '.pdf':
        return Icons.picture_as_pdf_outlined;
      case '.doc':
      case '.docx':
        return Icons.description_outlined;
      case '.zip':
      case '.rar':
        return Icons.archive_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
  @override
Widget build(BuildContext context) {
  return WillPopScope(
    onWillPop: _onWillPop,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0,
        leading: _pathStack.length > 1 ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _onWillPop()) : null,
        title: Text(_currentPath.isEmpty ? 'Файли' : path.basename(_currentPath), style: const TextStyle(fontWeight: FontWeight.normal)),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _showCreateFolderDialog,
            tooltip: 'Створити папку',
          ),
        ],
      ),
      body: FutureBuilder<List<FileSystemItem>>(
        future: _futureCache[_currentPath],
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text('Помилка: ${snapshot.error}', textAlign: TextAlign.center),
              ),
            );
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('Ця папка порожня'));
          }

          final items = snapshot.data!;
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  // Залишаємо відступ знизу, але він більше не потрібен для FAB
                  padding: EdgeInsets.only(top: 10, bottom: MediaQuery.of(context).padding.bottom + 90),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    if (item.type == 'virtual_gallery') {
                      return Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.photo_library_outlined, color: Colors.deepPurpleAccent),
                            title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            onTap: () {
                              // Замість переходу на окремий екран,
                              // просто перемикаємо індекс на головному екрані
                              // Це більш "правильна" навігація для BottomNavBar
                              // Щоб це працювало, нам потрібен доступ до методу зміни індексу.
                              // Це робить код складнішим. Простіший варіант - залишити як є.
                              // Для простоти, залишимо MaterialPageRoute, це теж працює.
                               Navigator.push(context, MaterialPageRoute(builder: (_) => const GalleryScreen()));
                            },
                          ),
                          const Divider(height: 1),
                        ],
                      );
                    }
                    if (item.type == 'directory') {
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(item.name),
                        onTap: () => _navigateTo(item.name),
                      );
                    } else {
                      return ListTile(
                        leading: Icon(_getIconForFile(item.name)),
                        title: Text(item.name),
                        subtitle: Text(_formatBytes(item.size ?? 0, 1)),
                        onTap: () => _handleFileTap(item),
                      );
                    }
                  },
                ),
              ),
              if (_currentlyUploading != null)
                LinearProgressIndicator(value: _uploadProgress, minHeight: 10, backgroundColor: Colors.grey.shade300),
              if (_currentlyUploading != null)
                Padding(padding: const EdgeInsets.all(8.0), child: Text('Завантаження: $_currentlyUploading')),
              if (_currentlyDownloading != null)
                LinearProgressIndicator(value: _downloadProgress, minHeight: 10, backgroundColor: Colors.grey.shade300),
              if (_currentlyDownloading != null)
                Padding(padding: const EdgeInsets.all(8.0), child: Text('Скачування: $_currentlyDownloading')),
            ],
          );
        },
      ),
      // <--- ОСЬ КЛЮЧОВЕ ВИПРАВЛЕННЯ
      floatingActionButton: Padding(
        // Додаємо відступ знизу, рівний висоті навігаційної панелі + стандартний відступ
        padding: EdgeInsets.only(bottom: 80.0), 
        child: FloatingActionButton(
          onPressed: _pickAndUploadFiles,
          child: const Icon(Icons.add),
          tooltip: 'Завантажити файли',
        ),
      ),
    ),
  );
}
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipController = TextEditingController();
  final _photoSizeController = TextEditingController();
  final _photoQualityController = TextEditingController();
  final _previewSizeController = TextEditingController();
  final _previewQualityController = TextEditingController();

  List<String> _syncFolders = [];
  bool _isSyncing = false;
  bool _isLoading = false;
  bool _isAutoSyncEnabled = false; // <--- Додаємо прапорець автосинхронізації

  static const String _syncFolderKey = 'sync_folder_path';
  static const String _autoSyncKey = 'auto_sync_enabled';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSelectedSyncFolder();
    _loadServerSettings();
    _loadAutoSyncState();
  }

  Future<void> _loadAutoSyncState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isAutoSyncEnabled = prefs.getBool(_autoSyncKey) ?? false;
    });
  }
Future<void> _generateAllThumbnails() async {
  setState(() => _isLoading = true);
  try {
    final baseUrl = await apiService.getBaseUrl();
    if (baseUrl.isEmpty) return;
    final resp = await http.post(Uri.parse('$baseUrl/thumbnails/generate_all/'));
    if (resp.statusCode == 200) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Мініатюри згенеровано')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Помилка генерації: ${resp.body}')));
    }
  } finally {
    setState(() => _isLoading = false);
  }
}
  Future<void> _setAutoSyncState(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_autoSyncKey, value);
  setState(() {
    _isAutoSyncEnabled = value;
  });
  if (value) {
    service.invoke('updateSettings', {
      'server_ip': _ipController.text,
      'sync_folders': _syncFolders,
    });
    service.invoke('runImmediateSync');
    service.invoke('startPeriodicSync');
  } else {
    service.invoke('stopPeriodicSync');
  }
}

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString('server_ip') ?? '';
    });
  }

  Future<void> _saveSettings() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('server_ip', _ipController.text);
  // ОНОВЛЮЄМО СЕРВІС
  service.invoke('updateSettings', {
    'server_ip': _ipController.text,
    'sync_folders': _syncFolders,
  });
}


  Future<void> _loadSelectedSyncFolder() async {
  final prefs = await SharedPreferences.getInstance();
  setState(() {
    _syncFolders = prefs.getStringList(_syncFolderKey) ?? [];
  });
  // ОНОВЛЮЄМО СЕРВІС після завантаження
  service.invoke('updateSettings', {
    'server_ip': _ipController.text,
    'sync_folders': _syncFolders,
  });
}
Future<void> _addSyncFolder() async {
  if (!await _requestStoragePermission()) return;
  String? selectedDirectory = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Виберіть папку для синхронізації');
  if (selectedDirectory != null && !_syncFolders.contains(selectedDirectory)) {
    final prefs = await SharedPreferences.getInstance();
    _syncFolders.add(selectedDirectory);
    await prefs.setStringList(_syncFolderKey, _syncFolders);
    setState(() {});
    service.invoke('updateSettings', {
      'server_ip': _ipController.text,
      'sync_folders': _syncFolders,
    });
  }
}
Future<void> _removeSyncFolder(String folder) async {
  final prefs = await SharedPreferences.getInstance();
  _syncFolders.remove(folder);
  await prefs.setStringList(_syncFolderKey, _syncFolders);
  setState(() {});
  service.invoke('updateSettings', {
    'server_ip': _ipController.text,
    'sync_folders': _syncFolders,
  });
}


Future<void> _loadSelectedSyncFolders() async {
  final prefs = await SharedPreferences.getInstance();
  _syncFolders = prefs.getStringList(_syncFolderKey) ?? [];
  setState(() {});
  service.invoke('updateSettings', {
    'server_ip': _ipController.text,
    'sync_folders': _syncFolders,
  });
}


  Future<void> _selectSyncFolder() async {
  if (!await _requestStoragePermission()) return;
  String? selectedDirectory = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Виберіть папку для синхронізації');
  if (selectedDirectory != null) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_syncFolderKey, selectedDirectory);
    setState(() => _syncFolders = selectedDirectory as List<String>);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Папку для синхронізації вибрано.')));
    // ОНОВЛЮЄМО СЕРВІС
    service.invoke('updateSettings', {
      'server_ip': _ipController.text,
      'sync_folders': [selectedDirectory],
    });
  }
}

  Future<void> _clearSyncFolder() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_syncFolderKey);
  setState() => _syncFolders.isEmpty;
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Вибір папки синхронізації скинуто.')));
  // ОНОВЛЮЄМО СЕРВІС
  service.invoke('updateSettings', {
    'server_ip': _ipController.text,
    'sync_folders': [],
  });
}

  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      if (sdkInt >= 33) {
        final statuses = await [Permission.photos, Permission.videos].request();
        return statuses.values.every((s) => s.isGranted);
      } else {
        final status = await Permission.storage.request();
        return status.isGranted;
      }
    }
    return true;
  }

  Future<void> _loadServerSettings() async {
    setState(() => _isLoading = true);
    try {
      final baseUrl = await apiService.getBaseUrl();
      if (baseUrl.isEmpty) return;
      final resp = await http.get(Uri.parse('$baseUrl/settings/'));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        setState(() {
          _previewSizeController.text = data['preview_size']?.toString() ?? '';
          _previewQualityController.text = data['preview_quality']?.toString() ?? '';
          _photoSizeController.text = data['photo_size']?.toString() ?? '';
          _photoQualityController.text = data['photo_quality']?.toString() ?? '';
        });
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveServerSettings() async {
    setState(() => _isLoading = true);
    try {
      final baseUrl = await apiService.getBaseUrl();
      if (baseUrl.isEmpty) return;
      final resp = await http.post(
        Uri.parse('$baseUrl/settings/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'preview_size': int.tryParse(_previewSizeController.text) ?? 400,
          'preview_quality': int.tryParse(_previewQualityController.text) ?? 80,
          'photo_size': int.tryParse(_photoSizeController.text) ?? 0,
          'photo_quality': int.tryParse(_photoQualityController.text) ?? 100,
        }),
      );
      if (resp.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Налаштування збережено')));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }
String _formatFolderPath(String fullPath) {
  // Повертає останні 2 сегменти шляху, наприклад DCIM/Camera
  final parts = fullPath.split('/');
  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}/${parts.last}';
  }
  return fullPath;
}
  Future<void> _clearThumbnailsCache() async {
    setState(() => _isLoading = true);
    try {
      final baseUrl = await apiService.getBaseUrl();
      if (baseUrl.isEmpty) return;
      final resp = await http.post(Uri.parse('$baseUrl/thumbnails/clear_cache/'));
      if (resp.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Кеш мініатюр очищено')));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sectionHeaderStyle = theme.textTheme.titleSmall?.copyWith(
      color: colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final descriptionStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      backgroundColor: colorScheme.surface.withOpacity(0.98),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            //const SizedBox(height: kToolbarHeight),
            Text('Підключення до сервера', style: sectionHeaderStyle),
            const SizedBox(height: 8),
            TextField(
              controller: _ipController,
              decoration: InputDecoration(
                labelText: 'IP Адреса та Порт Сервера',
                hintText: 'Напр.: 192.168.1.100:5000',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.dns_outlined),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              enabled: !_isLoading,
              onChanged: (_) => _saveSettings(),
            ),
            const SizedBox(height: 8),
            Text("Адреса вашого домашнього сервера, де запущені фото та відео.", style: descriptionStyle),
            const SizedBox(height: 24),
            Divider(height: 1, thickness: 0.5, color: colorScheme.outlineVariant),
            const SizedBox(height: 16),

            Text('Синхронізація на сервер', style: sectionHeaderStyle),
            const SizedBox(height: 16),

for (final folder in _syncFolders) ...[
  ListTile(
    leading: const Icon(Icons.folder_copy_outlined),
    title: const Text('Папка для синхронізації'),
    subtitle: Text(
      _formatFolderPath(folder),
      style: descriptionStyle?.copyWith(
        fontStyle: FontStyle.normal,
      ),
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      icon: const Icon(Icons.clear, size: 20),
      tooltip: 'Скинути вибір папки',
      onPressed: _isLoading ? null : () => _removeSyncFolder(folder),
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    tileColor: colorScheme.surfaceVariant.withOpacity(0.3),
    onTap: _isLoading ? null : () async {
      await _addSyncFolder();
    },
    enabled: !_isLoading,
  ),
  const SizedBox(height: 8), // <-- Відступ між плитками
],
if (_syncFolders.isEmpty)
  ListTile(
    leading: const Icon(Icons.folder_copy_outlined),
    title: const Text('Папка для синхронізації'),
    subtitle: Text(
      'Не вибрано',
      style: descriptionStyle?.copyWith(
        fontStyle: FontStyle.italic,
      ),
      overflow: TextOverflow.ellipsis,
    ),
    trailing: null,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    tileColor: colorScheme.surfaceVariant.withOpacity(0.3),
    onTap: _isLoading ? null : () async {
      await _addSyncFolder();
    },
    enabled: !_isLoading,
  ),
const SizedBox(height: 8),
Text(
  'Виберіть папку на пристрої, вміст якої (фото/відео) буде автоматично завантажуватись на сервер.',
  style: descriptionStyle,
),
const SizedBox(height: 16),

SwitchListTile(
  value: _isAutoSyncEnabled,
  onChanged: (_syncFolders.isEmpty || _isLoading) ? null : _setAutoSyncState,
  title: const Text('Автоматична синхронізація'),
  subtitle: Text(
    'Увімкніть, щоб синхронізація запускалась автоматично у фоні.',
    style: descriptionStyle,
  ),
  activeColor: colorScheme.primary,
  contentPadding: EdgeInsets.zero,
),
            // --- (Опціонально) Кнопка ручної синхронізації ---
            //ElevatedButton.icon(
              //icon: const Icon(Icons.sync_outlined),
              //label: const Text('Синхронізувати зараз'),
              //style: ElevatedButton.styleFrom(
                //backgroundColor: colorScheme.tertiaryContainer,
                //foregroundColor: colorScheme.onTertiaryContainer,
              //),
              //onPressed: (_selectedSyncFolderPath == null || _isLoading || _isSyncing) ? null : () {
                //service.invoke('runImmediateSync');
                //ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Синхронізація запущена')));
              //},
            //),
            const SizedBox(height: 24),
            Divider(height: 1, thickness: 0.5, color: colorScheme.outlineVariant),
            const SizedBox(height: 16),

            Text('Якість зображень (з сервера)', style: sectionHeaderStyle),
            const SizedBox(height: 16),
            _buildSettingsTextField(
              controller: _photoSizeController,
              label: 'Розмір повного фото (px)',
              hint: 'Макс. сторона, напр. 2000',
              description: 'Зменшує розмір фото для швидшого завантаження з сервера.',
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            _buildSettingsTextField(
              controller: _photoQualityController,
              label: 'Якість повного фото (%)',
              hint: '0-100, напр. 60',
              description: 'Якість стиснення JPEG для повних фото (0 - найгірша, 100 - найкраща).',
              enabled: !_isLoading,
              maxValue: 100,
            ),
            const SizedBox(height: 24),
            Divider(height: 1, thickness: 0.5, color: colorScheme.outlineVariant),
            const SizedBox(height: 16),

            Text('Мініатюри (з сервера)', style: sectionHeaderStyle),
            const SizedBox(height: 16),
            _buildSettingsTextField(
              controller: _previewSizeController,
              label: 'Розмір мініатюри (px)',
              hint: 'Макс. сторона, напр. 300',
              description: 'Розмір мініатюр, що відображаються у сітці галереї.',
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            _buildSettingsTextField(
              controller: _previewQualityController,
              label: 'Якість мініатюри (%)',
              hint: '0-100, напр. 40',
              description: 'Якість стиснення JPEG для мініатюр (менша якість = швидше завантаження сітки).',
              enabled: !_isLoading,
              maxValue: 100,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('Зберегти налаштування якості на сервері'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _isLoading ? null : _saveServerSettings,
            ),
            const SizedBox(height: 24),
            Divider(height: 1, thickness: 0.5, color: colorScheme.outlineVariant),
            const SizedBox(height: 16),

            Text('Додаткові дії', style: sectionHeaderStyle),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Очистити кеш мініатюр на сервері'),
              subtitle: const Text('Видалити згенеровані мініатюри на сервері. Вони будуть створені заново при наступному запиті.'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              tileColor: colorScheme.surfaceVariant.withOpacity(0.3),
              onTap: _isLoading ? null : _clearThumbnailsCache,
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            ListTile(
  leading: const Icon(Icons.refresh_outlined),
  title: const Text('Згенерувати всі мініатюри заново'),
  subtitle: const Text('Створити нові мініатюри для всіх фото/відео згідно з поточними налаштуваннями якості.'),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  tileColor: colorScheme.surfaceVariant.withOpacity(0.3),
  onTap: _isLoading ? null : _generateAllThumbnails,
  enabled: !_isLoading,
),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Про додаток'),
              subtitle: const Text('Версія та інформація'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              tileColor: colorScheme.surfaceVariant.withOpacity(0.3),
              onTap: _isLoading ? null : () {
                showAboutDialog(
                  context: context,
                  applicationName: 'My Personal Cloud',
                  applicationVersion: '1.0.0',
                );
              },
              enabled: !_isLoading,
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required String description,
    required bool enabled,
    int? maxValue,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final descriptionStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            prefixIcon: const Icon(Icons.tune_outlined),
          ),
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
            if (maxValue != null)
              TextInputFormatter.withFunction((oldValue, newValue) {
                final int? value = int.tryParse(newValue.text);
                if (value != null && value > maxValue) {
                  return oldValue;
                }
                return newValue;
              }),
          ],
          textInputAction: TextInputAction.next,
          enabled: enabled,
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(description, style: descriptionStyle),
        ),
      ],
    );
  }
}