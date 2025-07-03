# generate_thumbnails.py
import os
from PIL import Image

# Шляхи до папок, такі ж як у сервері
STORAGE_PATH = "storage"
ORIGINALS_PATH = os.path.join(STORAGE_PATH, "originals")
THUMBNAILS_PATH = os.path.join(STORAGE_PATH, "thumbnails")

def create_thumbnail(image_path: str, thumbnail_path: str):
    try:
        size = (550, 550)
        quality = 60
        with Image.open(image_path) as img:
            img.thumbnail(size)
            if img.mode in ("RGBA", "LA"):
                # Конвертуємо до RGB, якщо є альфа-канал
                background = Image.new("RGB", img.size, (255, 255, 255))
                background.paste(img, mask=img.split()[-1])
                img = background
            elif img.mode != "RGB":
                img = img.convert("RGB")
            img.save(thumbnail_path, "JPEG", quality=quality, optimize=True)
        print(f"OK: Thumbnail created for {os.path.basename(image_path)}")
    except Exception as e:
        # Ігноруємо файли, які не є зображеннями (наприклад, .DS_Store)
        if not image_path.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.bmp')):
             print(f"SKIP: Skipping non-image file {os.path.basename(image_path)}")
        else:
            print(f"ERROR: Could not create thumbnail for {os.path.basename(image_path)}: {e}")

if __name__ == "__main__":
    print("Starting thumbnail generation...")
    os.makedirs(THUMBNAILS_PATH, exist_ok=True)
    
    # Отримуємо список оригіналів та існуючих прев'ю
    original_files = set(os.listdir(ORIGINALS_PATH))
    thumbnail_files = set(os.listdir(THUMBNAILS_PATH))

    # Генеруємо прев'ю тільки для тих файлів, для яких їх ще немає
    for filename in original_files:
        if filename not in thumbnail_files:
            print(f"Processing {filename}...")
            original_file_path = os.path.join(ORIGINALS_PATH, filename)
            thumbnail_file_path = os.path.join(THUMBNAILS_PATH, filename)
            create_thumbnail(original_file_path, thumbnail_file_path)
        else:
             print(f"SKIP: Thumbnail for {filename} already exists.")

    print("Done!")