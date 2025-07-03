# server.py - Фінальна версія з отриманням ОРИГІНАЛЬНОЇ дати

import os
import shutil
import json
import time
from datetime import datetime
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from PIL import Image
from PIL.ExifTags import TAGS
import ffmpeg
from hachoir.parser import createParser
from hachoir.metadata import extractMetadata
from fastapi import FastAPI, UploadFile, File, HTTPException, Form, Body
import io

# --- Налаштування (без змін) ---
app = FastAPI(title="My Personal Cloud API")
STORAGE_PATH = "storage"
ORIGINALS_PATH = os.path.join(STORAGE_PATH, "originals")
THUMBNAILS_PATH = os.path.join(STORAGE_PATH, "thumbnails")
METADATA_FILE = os.path.join(STORAGE_PATH, "metadata.json")

os.makedirs(ORIGINALS_PATH, exist_ok=True)
os.makedirs(THUMBNAILS_PATH, exist_ok=True)


# --- Функції для роботи з метаданими (без змін) ---
# ... (load_metadata, save_metadata) ...
def load_metadata():
    if not os.path.exists(METADATA_FILE): return {}
    try:
        with open(METADATA_FILE, 'r', encoding='utf-8') as f: return json.load(f)
    except (json.JSONDecodeError, FileNotFoundError): return {}

def save_metadata(data):
    with open(METADATA_FILE, 'w', encoding='utf-8') as f: json.dump(data, f, indent=4, ensure_ascii=False)


# --- Функції для створення прев'ю (без змін) ---
# ... (create_photo_thumbnail, create_video_thumbnail) ...
def create_photo_thumbnail(image_path: str, thumbnail_path: str):
    try:
        settings = load_settings()
        size = (settings.get("preview_size", 400), settings.get("preview_size", 400))
        quality = settings.get("preview_quality", 80)
        with Image.open(image_path) as img:
            if img.format and img.format.upper() in ['HEIC', 'HEIF']:
                from pillow_heif import register_heif_opener
                register_heif_opener()
                img = Image.open(image_path)
            if img.mode in ("RGBA", "P"): img = img.convert("RGB")
            img.thumbnail(size)
            img.save(thumbnail_path, "JPEG", quality=quality, optimize=True)
        return True
    except Exception as e:
        print(f"❌ Помилка фото-прев'ю для {os.path.basename(image_path)}: {e}")
        return False

def create_video_thumbnail(video_path: str, thumbnail_path: str):
    try:
        settings = load_settings()
        size = settings.get("preview_size", 400)
        (ffmpeg.input(video_path, ss=1).filter('scale', size, -1).output(thumbnail_path, vframes=1).overwrite_output().run(capture_stdout=True, capture_stderr=True))
        return True
    except ffmpeg.Error as e:
        print(f"❌ Помилка FFmpeg для {os.path.basename(video_path)}: {e.stderr.decode()}")
        return False


# =================================================================
# НОВА ФУНКЦІЯ ДЛЯ ОТРИМАННЯ ОРИГІНАЛЬНОЇ ДАТИ
# =================================================================
def get_original_date(file_path: str) -> float:
    """
    Намагається отримати оригінальну дату створення з метаданих файлу.
    Якщо не вдається, повертає дату зміни файлу в системі.
    """
    try:
        # Для фотографій (JPEG/HEIC)
        if file_path.lower().endswith(('.jpg', '.jpeg', '.heic')):
            with Image.open(file_path) as img:
                exif_data = img._getexif()
                if exif_data:
                    for tag, value in exif_data.items():
                        tag_name = TAGS.get(tag, tag)
                        if tag_name == 'DateTimeOriginal':
                            # Формат 'YYYY:MM:DD HH:MM:SS'
                            dt_obj = datetime.strptime(value, '%Y:%m:%d %H:%M:%S')
                            print(f"✅ Знайдено дату в EXIF: {dt_obj}")
                            return dt_obj.timestamp()
    except Exception:
        pass # Просто ігноруємо помилки читання EXIF

    try:
        # Для відео (MP4/MOV) за допомогою Hachoir
        parser = createParser(file_path)
        if parser:
            with parser:
                metadata = extractMetadata(parser)
            if metadata and metadata.has('creation_date'):
                dt_obj = metadata.get('creation_date')
                print(f"✅ Знайдено дату в метаданих відео: {dt_obj}")
                return dt_obj.timestamp()
    except Exception:
        pass # Ігноруємо помилки Hachoir

    # Якщо нічого не знайдено, повертаємо час останньої зміни файлу
    fallback_timestamp = os.path.getmtime(file_path)
    print(f"⚠️ Не вдалося знайти оригінальну дату, використовую fallback: {datetime.fromtimestamp(fallback_timestamp)}")
    return fallback_timestamp


# =================================================================
# ОНОВЛЕНІ ГОЛОВНІ ЕНДПОІНТИ
# =================================================================
# server.py

# ... (всі імпорти та функції-хелпери без змін) ...

# <--- ЗМІНА: Модифікуємо існуючий ендпоінт
@app.get("/files/list/")
async def list_files_in_path(path: str = ""):
    base_path = os.path.abspath(ORIGINALS_PATH)
    requested_path = os.path.abspath(os.path.join(base_path, path))

    if not requested_path.startswith(base_path):
        raise HTTPException(status_code=403, detail="Access denied")
    if not os.path.isdir(requested_path):
        raise HTTPException(status_code=404, detail="Directory not found")

    items = []
    # <--- ЗМІНА: Завантажуємо метадані, щоб знати, які файли є частиною галереї
    gallery_metadata = load_metadata()
    gallery_files = set(gallery_metadata.keys()) # Використовуємо set для швидкого пошуку

    # Додаємо віртуальну папку "Галерея" тільки в корені
    if not path:
        items.append({"name": "Галерея", "type": "virtual_gallery"})

    try:
        for item_name in os.listdir(requested_path):
            item_path = os.path.join(requested_path, item_name)
            
            # <--- ЗМІНА: Фільтруємо файли, які є частиною галереї
            # Показуємо їх тільки якщо ми НЕ в кореневій папці
            if os.path.isfile(item_path) and item_name in gallery_files and not path:
                continue # Пропускаємо файли галереї в кореневій директорії

            if os.path.isdir(item_path):
                items.append({"name": item_name, "type": "directory"})
            else:
                size = os.path.getsize(item_path)
                items.append({"name": item_name, "type": "file", "size": size})
        
        # Сортування залишається тим самим
        items.sort(key=lambda x: (
            0 if x['type'] == 'virtual_gallery' else 1 if x['type'] == 'directory' else 2,
            x['name'].lower()
        ))
        return JSONResponse(content={"path": path, "items": items})
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# ... (решта коду сервера без змін) ...

@app.post("/files/create_folder/")
async def create_folder(path: str = Form(...), folder_name: str = Form(...)):
    base_path = os.path.abspath(ORIGINALS_PATH)
    target_dir_path = os.path.abspath(os.path.join(base_path, path))

    if not target_dir_path.startswith(base_path):
        raise HTTPException(status_code=403, detail="Access denied")
    if not os.path.isdir(target_dir_path):
        raise HTTPException(status_code=404, detail="Parent directory not found")

    new_folder_path = os.path.join(target_dir_path, folder_name)
    if os.path.exists(new_folder_path):
        raise HTTPException(status_code=409, detail="Folder with this name already exists")
    
    try:
        os.makedirs(new_folder_path)
        return {"status": "success", "message": f"Folder '{folder_name}' created."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# <--- НОВЕ: Ендпоінт для завантаження файлу в конкретну папку
@app.post("/files/upload_to_path/")
async def upload_file_to_path(file: UploadFile = File(...), path: str = Form("")):
    base_path = os.path.abspath(ORIGINALS_PATH)
    target_dir_path = os.path.abspath(os.path.join(base_path, path))

    if not target_dir_path.startswith(base_path):
        raise HTTPException(status_code=403, detail="Access denied")
    if not os.path.isdir(target_dir_path):
        raise HTTPException(status_code=404, detail="Target directory not found")

    file_location = os.path.join(target_dir_path, file.filename)
    
    with open(file_location, "wb+") as file_object:
        shutil.copyfileobj(file.file, file_object)

    # Якщо це медіафайл, оновлюємо метадані для галереї
    file_extension = os.path.splitext(file.filename.lower())[1]
    if file_extension in ['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.mov']:
        # Викликаємо логіку з твого головного ендпоінта /upload/
        # (це спрощення, в ідеалі цю логіку треба винести в окрему функцію)
        thumbnail_filename = f"{os.path.splitext(file.filename)[0]}.jpg"
        thumbnail_path = os.path.join(THUMBNAILS_PATH, thumbnail_filename)
        metadata = load_metadata()
        metadata[file.filename] = {
            "type": "image" if file_extension in ['.jpg', '.jpeg', '.png', '.gif'] else "video",
            "thumbnail": thumbnail_filename,
            "timestamp": get_original_date(file_location)
        }
        save_metadata(metadata)
        if metadata[file.filename]["type"] == "image":
             create_photo_thumbnail(file_location, thumbnail_path)
        else:
             create_video_thumbnail(file_location, thumbnail_path)


    return {"status": "success", "filename": file.filename}




@app.post("/upload/")
async def upload_file(file: UploadFile = File(...)):
    # ... (код визначення типів та збереження файлу залишається тим самим) ...
    supported_image_extensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.heic', 'webp']
    supported_video_extensions = ['.mp4', '.mov', '.avi', '.mkv', 'webm']
    original_file_path = os.path.join(ORIGINALS_PATH, file.filename)
    with open(original_file_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
    file_extension = os.path.splitext(file.filename.lower())[1]
    file_type = None
    if file_extension in supported_image_extensions: file_type = "image"
    elif file_extension in supported_video_extensions: file_type = "video"
    else: return {"filename": file.filename, "status": "skipped", "message": "Unsupported file type"}

    # ... (код створення прев'ю залишається тим самим) ...
    thumbnail_filename = f"{os.path.splitext(file.filename)[0]}.jpg"
    thumbnail_file_path = os.path.join(THUMBNAILS_PATH, thumbnail_filename)
    thumbnail_created = False
    if file_type == "image": thumbnail_created = create_photo_thumbnail(original_file_path, thumbnail_file_path)
    elif file_type == "video": thumbnail_created = create_video_thumbnail(original_file_path, thumbnail_file_path)

    if thumbnail_created:
        metadata = load_metadata()
        metadata[file.filename] = {
            "type": file_type,
            "thumbnail": thumbnail_filename,
            # --- ВИКОРИСТОВУЄМО НОВУ ФУНКЦІЮ ---
            "timestamp": get_original_date(original_file_path)
        }
        save_metadata(metadata)
        return {"filename": file.filename, "type": file_type, "status": "success"}
    else:
        raise HTTPException(status_code=500, detail="Could not create thumbnail")


# --- ЕНДПОІНТ get_gallery/ ЗАЛИШАЄТЬСЯ БЕЗ ЗМІН, він вже готовий ---
@app.get("/gallery/")
async def get_gallery_list():
    metadata = load_metadata()
    if not metadata: return []
    # Використовуємо .get() для безпечного отримання timestamp, на випадок старих записів
    sorted_items = sorted(metadata.items(), key=lambda item: item[1].get('timestamp', 0), reverse=True)
    gallery_list = [
        {"filename": key, "type": value["type"], "thumbnail": value["thumbnail"], "timestamp": value.get("timestamp")}
        for key, value in sorted_items if value.get("timestamp") # Віддаємо тільки ті, де є timestamp
    ]
    return JSONResponse(content=gallery_list)


@app.get("/thumbnail/{filename}")
# ... (без змін) ...
async def get_thumbnail(filename: str):
    file_path = os.path.join(THUMBNAILS_PATH, filename)
    if os.path.exists(file_path): return FileResponse(file_path)
    raise HTTPException(status_code=404, detail="Thumbnail not found")

@app.get("/original/{filename}")
# ... (без змін) ...
async def get_original_file(filename: str):
    file_path = os.path.join(ORIGINALS_PATH, filename)
    if os.path.exists(file_path): return FileResponse(file_path)
    raise HTTPException(status_code=404, detail="File not found")

@app.post("/gallery/rescan")
async def rescan_storage():
    # ... (цей код треба теж оновити, щоб він використовував get_original_date) ...
    supported_image_extensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.heic', 'webp']
    supported_video_extensions = ['.mp4', '.mov', '.avi', '.mkv', 'webm']
    metadata = load_metadata()
    original_files = os.listdir(ORIGINALS_PATH)
    processed_count, updated_count = 0, 0
    
    for filename in original_files:
        original_file_path = os.path.join(ORIGINALS_PATH, filename)
        # Перескануємо, тільки якщо запис неповний (немає timestamp)
        if filename in metadata and 'timestamp' in metadata[filename]: continue
            
        if filename in metadata: updated_count += 1
        else: processed_count += 1

        file_extension = os.path.splitext(filename.lower())[1]
        file_type = None
        if file_extension in supported_image_extensions: file_type = "image"
        elif file_extension in supported_video_extensions: file_type = "video"
        else: continue

        thumbnail_filename = f"{os.path.splitext(filename)[0]}.jpg"
        thumbnail_file_path = os.path.join(THUMBNAILS_PATH, thumbnail_filename)
        
        if not os.path.exists(thumbnail_file_path):
            created = False
            if file_type == "image": created = create_photo_thumbnail(original_file_path, thumbnail_file_path)
            elif file_type == "video": created = create_video_thumbnail(original_file_path, thumbnail_file_path)
            if not created: continue

        # --- ВИКОРИСТОВУЄМО НОВУ ФУНКЦІЮ І ТУТ ---
        metadata[filename] = {
            "type": file_type,
            "thumbnail": thumbnail_filename,
            "timestamp": get_original_date(original_file_path)
        }

    save_metadata(metadata)
    message = f"Scan complete. New: {processed_count}. Updated: {updated_count}."
    return {"status": "success", "message": message}

# --- Глобальні налаштування ---
SETTINGS_FILE = os.path.join(STORAGE_PATH, "settings.json")
DEFAULT_SETTINGS = {
    "preview_size": 400,
    "preview_quality": 80,
    "photo_size": 0,      # 0 = оригінал
    "photo_quality": 100,
}

def load_settings():
    if not os.path.exists(SETTINGS_FILE):
        return DEFAULT_SETTINGS.copy()
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            return {**DEFAULT_SETTINGS, **json.load(f)}
    except Exception:
        return DEFAULT_SETTINGS.copy()

def save_settings(settings):
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)

@app.get("/settings/")
async def get_settings():
    return load_settings()

@app.post("/settings/")
async def update_settings(data: dict = Body(...)):
    settings = load_settings()
    for key in DEFAULT_SETTINGS:
        if key in data:
            settings[key] = data[key]
    save_settings(settings)
    return {"status": "success", "settings": settings}

@app.post("/thumbnails/clear_cache/")
async def clear_thumbnails_cache():
    try:
        for fname in os.listdir(THUMBNAILS_PATH):
            fpath = os.path.join(THUMBNAILS_PATH, fname)
            if os.path.isfile(fpath):
                os.remove(fpath)
        return {"status": "success", "message": "Thumbnail cache cleared"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

print("🚀 Сервер готовий до роботи! (v_final, з оригінальною датою)")

@app.get("/original_resized/{filename}")
async def get_resized_original(filename: str):
    file_path = os.path.join(ORIGINALS_PATH, filename)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")
    settings = load_settings()
    max_size = settings.get("photo_size", 0)
    quality = settings.get("photo_quality", 100)
    ext = os.path.splitext(filename.lower())[1]
    # Якщо не зображення — просто віддаємо файл
    if ext not in [".jpg", ".jpeg", ".png", ".heic", ".webp"]:
        return FileResponse(file_path)
    try:
        with Image.open(file_path) as img:
            # HEIC/HEIF підтримка
            if img.format and img.format.upper() in ['HEIC', 'HEIF']:
                from pillow_heif import register_heif_opener
                register_heif_opener()
                img = Image.open(file_path)
            if img.mode in ("RGBA", "P"):
                img = img.convert("RGB")
            # Якщо max_size > 0 — змінюємо розмір
            if max_size and max_size > 0:
                img.thumbnail((max_size, max_size))
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=quality, optimize=True)
            buf.seek(0)
            return StreamingResponse(buf, media_type="image/jpeg")
    except Exception as e:
        print(f"Помилка стискання: {e}")
        return FileResponse(file_path)

@app.post("/thumbnails/generate_all/")
async def generate_all_thumbnails():
    """
    Генерує мініатюри для всіх медіафайлів у ORIGINALS_PATH згідно з поточними налаштуваннями.
    """
    supported_image_extensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.heic', 'webp']
    supported_video_extensions = ['.mp4', '.mov', '.avi', '.mkv', 'webm']
    metadata = load_metadata()
    original_files = os.listdir(ORIGINALS_PATH)
    generated, failed = 0, 0

    for filename in original_files:
        original_file_path = os.path.join(ORIGINALS_PATH, filename)
        file_extension = os.path.splitext(filename.lower())[1]
        file_type = None
        if file_extension in supported_image_extensions:
            file_type = "image"
        elif file_extension in supported_video_extensions:
            file_type = "video"
        else:
            continue

        thumbnail_filename = f"{os.path.splitext(filename)[0]}.jpg"
        thumbnail_file_path = os.path.join(THUMBNAILS_PATH, thumbnail_filename)

        try:
            if file_type == "image":
                created = create_photo_thumbnail(original_file_path, thumbnail_file_path)
            else:
                created = create_video_thumbnail(original_file_path, thumbnail_file_path)
            if created:
                generated += 1
            else:
                failed += 1
        except Exception as e:
            print(f"Помилка при створенні мініатюри для {filename}: {e}")
            failed += 1

    return {"status": "success", "generated": generated, "failed": failed}