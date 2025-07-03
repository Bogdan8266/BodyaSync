import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';

// ЗАМІНИ ЦЕ НА IP-АДРЕСУ СВОГО RASPBERRY PI
const String RPI_API_URL = "http://192.168.2.34:8000"; // Приклад

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late Future<List<String>> _galleryFiles;

  @override
  void initState() {
    super.initState();
    _galleryFiles = fetchGalleryFiles();
  }

  Future<List<String>> fetchGalleryFiles() async {
    try {
      final response = await http.get(Uri.parse('$RPI_API_URL/gallery/'));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        List<String> files = List<String>.from(data['files']);
        return files;
      } else {
        throw Exception('Failed to load gallery');
      }
    } catch (e) {
      // Показуємо помилку користувачу
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Помилка завантаження галереї: $e')),
      );
      return []; // Повертаємо пустий список у разі помилки
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _galleryFiles,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text('Помилка: ${snapshot.error}'));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text('Ваша галерея порожня'));
        }

        final files = snapshot.data!;

        return GridView.builder(
          // Додаємо відступи, щоб контент не заходив під панелі
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 60,
            bottom: MediaQuery.of(context).padding.bottom + 80,
            left: 4,
            right: 4,
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4, // 4 колонки, як ти хотів
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: files.length,
          itemBuilder: (context, index) {
            final filename = files[index];
            final thumbnailUrl = '$RPI_API_URL/thumbnail/$filename';

            // Використовуємо CachedNetworkImage для ефективності
            return CachedNetworkImage(
              imageUrl: thumbnailUrl,
              fit: BoxFit.cover,
              // Показуємо заглушку, поки вантажиться
              placeholder: (context, url) => Container(
                color: Colors.grey[300],
              ),
              // Показуємо іконку помилки, якщо не змогло завантажити
              errorWidget: (context, url, error) => const Icon(Icons.error),
            );
          },
        );
      },
    );
  }
}