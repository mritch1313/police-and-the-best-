class_name GraphicsConfig
extends ConfigResource
## Политика выбора качества. `auto_tier` включает адаптивный пониже/повыше по FPS,
## `forced_tier` — ручной выбор игрока (0=low, 1=medium, 2=high, -1=авто).

@export var auto_tier: bool = true
@export_range(-1, 2, 1) var forced_tier: int = -1
@export_range(20.0, 240.0, 1.0) var fps_target: float = 60.0
## Ниже этого FPS в течение `check_window_s` — downgrade.
@export_range(10.0, 59.0, 0.5) var downgrade_fps: float = 42.0
## Выше этого — upgrade (только если авто и предыдущий замер тоже был хорошим).
@export_range(20.0, 240.0, 0.5) var upgrade_fps: float = 57.0
@export_range(0.5, 20.0, 0.5) var check_window_s: float = 3.0
## Сколько подряд «плохих»/«хороших» замеров нужно для смены уровня.
@export_range(1, 8, 1) var confirmations: int = 2
@export var vsync: bool = true
@export_range(0, 4, 1) var initial_tier_for_low_ram: int = 0
@export var section_for_tier_0: String = "graphics.tier_low"
@export var section_for_tier_1: String = "graphics.tier_medium"
@export var section_for_tier_2: String = "graphics.tier_high"

func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if downgrade_fps >= upgrade_fps:
		problems.append(_problem("downgrade_fps должен быть меньше upgrade_fps, иначе уровни будут переключаться туда-сюда"))
	if fps_target < upgrade_fps:
		problems.append(_problem("upgrade_fps выше fps_target — апгрейд никогда не сработает"))
	return problems
