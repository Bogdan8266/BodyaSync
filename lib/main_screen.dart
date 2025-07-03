import 'package:flutter/material.dart';
import 'package:glass_kit/glass_kit.dart';
import 'gallery_screen.dart'; // Створимо цей файл далі

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _widgetOptions = <Widget>[
    GalleryScreen(), // Наша галерея
    Text('Files Page (to be implemented)'), // Заглушка для файлів
    Text('Settings Page (to be implemented)'), // Заглушка для налаштувань
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Розширюємо тіло за AppBar, щоб був ефект прозорості
      extendBodyBehindAppBar: true, 
      extendBody: true, // Розширюємо тіло за BottomBar

      // --- Верхня панель з розмиттям ---
      appBar: PreferredSize(
        preferredSize: const Size(double.infinity, 56.0),
        child: GlassContainer(
          height: 120, // Висота з урахуванням зони StatusBar
          width: double.infinity,
          blur: 10,
          color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
          borderColor: Colors.transparent,
          child: const SafeArea(
            child: Center(
              child: Text(
                'My Personal Cloud',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ),
      
      body: Center(
        child: _widgetOptions.elementAt(_selectedIndex),
      ),

      // --- Нижня панель з розмиттям ---
      bottomNavigationBar: GlassContainer(
        height: 80,
        width: double.infinity,
        blur: 10,
        color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
        borderColor: Colors.transparent,
        child: NavigationBar(
          backgroundColor: Colors.transparent, // Робимо фон прозорим
          indicatorColor: Theme.of(context).colorScheme.primaryContainer,
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onItemTapped,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.photo_library_outlined),
              selectedIcon: Icon(Icons.photo_library),
              label: 'Галерея',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Файли',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Налаштування',
            ),
          ],
        ),
      ),
    );
  }
}