# Сюда кладут модели машин

Один файл = одна модель. Godot импортирует `.glb` / `.gltf` / `.fbx` сам; `.import`-файлы в git
не лежат (их перегенерирует `godot --headless --import` — это делает и CI).

Подключение — текстом, без редактора:

```ini
; res://override_cfg/vehicle.cfg  (или user://override_cfg/vehicle.cfg)
[vehicle.player]
visual_scene = "res://assets/models/sedan.glb"
```

Требования к мешу, система координат, лимиты по треугольникам/материалам и контракт
`setup()/sync_from_physics()` — в `docs/CAR_MODEL.md`.

Если путь битый или тип не тот, `visual_scene` останется `null` и включится процедурная
модель, а в `Config.warnings` попадёт запись — то есть игра не сломается. Это проверяет
автотест `visual_scene_swap_from_cfg`.
