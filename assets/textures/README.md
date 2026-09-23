# Сюда кладут текстуры (необязательно)

`TextureLibrary` (`scripts/render/texture_library.gd`) умеет **генерировать** все текстуры
сам — проект запускается с пустой папкой. Но если рядом лежит файл с нужным именем,
используется он, а не генерация:

```
res://assets/textures/<имя>.png          albedo
res://assets/textures/_<имя>_normal.png   карта нормалей (необязательно)
res://assets/textures/_<имя>_rough.png    шероховатость, канал R (необязательно)
```

Имена (`TextureLibrary.names()`): `asphalt`, `concrete`, `sidewalk`, `road_marking`,
`facade_office`, `facade_brick`, `facade_glass`, `facade_residential`, `roof_gravel`,
`metal_panel`, `brick`, `paint_wear`, `tyre_rubber`, `rim_metal`, `soil`, `glass_sheet`.

Практические требования под мобильное железо:

* размер тайла в метрах берётся НЕ из PNG, а из `TextureLibrary._tile_size(name)` — делай
  текстуру бесшовной на том же масштабе, что и процедурная (256 px на тайл);
* степени двойки (512 или 1024), квадратная;
* сжатие при импорте включено глобально (`import_etc2_astc = true`, ETC2/ASTC) — без этого
  экспорт на Android падает с «ETC2/ASTC texture compression is required»;
* `normal` — OpenGL-конвенции (Y вверх), как в Godot по умолчанию;
* альфа в albedo = прозрачность материала (включит `TRANSPARENCY_ALPHA` у материала, если
  он это поддерживает) — для стекла лучше оставить `glass_sheet` процедурным.

После добавления файлов прогони `godot --headless --import` и `python3 tools/validate_project.py`
(проверка, что на каждый `res://`-путь в коде есть файл).
