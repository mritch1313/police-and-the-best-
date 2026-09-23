extends Node
## PerformanceManager — уровень качества и адаптивное поведение под мобильное железо.
##
## Три пресета (low/medium/high) описаны в `autoloads/graphics.cfg` как [QualityTier].
## Менеджер умеет сам понижать/повышать уровень по FPS (окно замеров + гистерезис),
## применяет пресет к Viewport/свету/туману и раздаёт «бюджеты» (плотность реквизита,
## дистанции отсечки, число чанков) стримеру, генератору и HUD.
##
## Тяжёлые эффекты (SSR, volumetric fog, real-time GI, screen-space reflections)
## здесь не включаются никогда — они не для Mali-G52.

signal tier_changed(index: int, tier: QualityTier)

const TIER_NAMES := ["low", "medium", "high"]
const LOW_RAM_ANDROID_MB := 5000

var tiers: Array[QualityTier] = []
var tier_index: int = 1
var auto: bool = true
var configured_by_device: bool = false
var fps: float = 60.0
var frame_ms: float = 16.6
var avg_frame_ms: float = 16.6
var downgrades: int = 0
var upgrades: int = 0
var manual_override: bool = false

var _window: float = 3.0
var _accumulator: float = 0.0
var _frames: int = 0
var _bad_streak: int = 0
var _good_streak: int = 0
var _confirmations: int = 2
var _downgrade_fps: float = 42.0
var _upgrade_fps: float = 57.0

func _ready() -> void:
	var gcfg: GraphicsConfig = GameSetup.graphics
	if gcfg != null:
		_window = gcfg.check_window_s
		_confirmations = int(gcfg.confirmations)
		_downgrade_fps = gcfg.downgrade_fps
		_upgrade_fps = gcfg.upgrade_fps
		tiers = gcfg_tiers()
		auto = gcfg.auto_tier and gcfg.forced_tier < 0
		manual_override = gcfg.forced_tier >= 0
		if manual_override:
			tier_index = clampi(gcfg.forced_tier, 0, maxi(gcfg_tiers().size() - 1, 0))
		Engine.max_fps = int(gcfg.fps_target)
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if gcfg.vsync else DisplayServer.VSYNC_DISABLED
		)
	else:
		push_warning("PerformanceManager: GraphicsConfig не задан — остаётся средний пресет")
	_build_default_tiers_if_needed()
	tier_index = clampi(tier_index, 0, maxi(tiers.size() - 1, 0))
	if not manual_override:
		tier_index = _device_hint()
		configured_by_device = true
		# Размер shadow atlas читается рендерером на старте: задать его можно только сейчас
		# (и он же — единственная настройка, требующая перезапуска для смены).
		ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/size", tiers[tier_index].shadow_atlas_size)
	apply_tier()
	DebugConsole.log_line("perf", "качество: %s (авто=%s, по подсказке устройства=%s)" % [
		tier_name(), str(auto and not manual_override), str(configured_by_device),
	])

func gcfg_tiers() -> Array[QualityTier]:
	return GameSetup.quality_tiers()

func _process(delta: float) -> void:
	fps = Engine.get_frames_per_second()
	frame_ms = delta * 1000.0
	avg_frame_ms = lerpf(avg_frame_ms, frame_ms, clampf(delta * 2.0, 0.0, 1.0))
	if not auto or manual_override:
		return
	_accumulator += delta
	_frames += 1
	if _accumulator < _window:
		return
	var measured := float(_frames) / maxf(_accumulator, 0.001)
	_accumulator = 0.0
	_frames = 0
	if measured < _downgrade_fps and tier_index > 0:
		_bad_streak += 1
		_good_streak = 0
	elif measured > _upgrade_fps and tier_index < tiers.size() - 1:
		_good_streak += 1
		_bad_streak = 0
	else:
		_bad_streak = 0
		_good_streak = 0
	if _bad_streak >= _confirmations:
		_bad_streak = 0
		downgrades += 1
		set_tier(tier_index - 1, true)
	elif _good_streak >= _confirmations:
		_good_streak = 0
		upgrades += 1
		set_tier(tier_index + 1, true)

func _build_default_tiers_if_needed() -> void:
	if not tiers.is_empty():
		return
	for i in range(TIER_NAMES.size()):
		var t := QualityTier.new()
		t.display_name = TIER_NAMES[i]
		tiers.append(t)
	tiers[0].shadows_enabled = false
	tiers[0].prop_density = 0.5
	tiers[0].rendering_scale = 0.85
	tiers[0].max_chunks = 6
	tiers[2].shadow_atlas_size = 2048
	tiers[2].prop_density = 1.5

## Подсказка по железу: мобильная ОС и/или мало памяти -> ниже пресет.
func _device_hint() -> int:
	var os_name := OS.get_name()
	var memory := OS.get_total_memory_mb()
	# Какой пресет считать «безопасным для малопамятников» - решение конфига
	# (initial_tier_for_low_ram), а не зашитая в код единица.
	var low_tier := 0
	if GameSetup.graphics != null:
		low_tier = clampi(GameSetup.graphics.initial_tier_for_low_ram, 0, maxi(tiers.size() - 1, 0))
	if os_name == "Android" or os_name == "iOS":
		if memory > 0 and memory < LOW_RAM_ANDROID_MB:
			return low_tier
		return clampi(low_tier + 1, 0, maxi(tiers.size() - 1, 0))
	if memory > 0 and memory < 3072:
		return low_tier
	return maxi(tiers.size() - 1, 0)

func tier() -> QualityTier:
	if tiers.is_empty():
		return null
	return tiers[clampi(tier_index, 0, tiers.size() - 1)]

func tier_name() -> String:
	return TIER_NAMES[clampi(tier_index, 0, TIER_NAMES.size() - 1)]

func set_tier(index: int, from_auto: bool = false) -> void:
	if index < 0:
		auto = true
		manual_override = false
		if GameSetup.graphics != null:
			GameSetup.graphics.forced_tier = -1
			GameSetup.graphics.auto_tier = true
		DebugConsole.log_line("perf", "качество: снова автоматически")
		return
	manual_override = not from_auto
	auto = not manual_override
	var next_index := clampi(index, 0, maxi(tiers.size() - 1, 0))
	var changed := next_index != tier_index
	tier_index = next_index
	apply_tier()
	if changed:
		DebugConsole.log_line("perf", "качество -> %s%s" % [tier_name(), " (авто)" if from_auto else ""])
		SaveManager.set_value("profile", "graphics_tier", -1 if auto else tier_index)
		SaveManager.set_value("profile", "auto_quality", auto)
		SaveManager.flush()

## Применить пресет к рендереру; WorldRig/HUD/стример реагируют на сигнал.
func apply_tier() -> void:
	var t := tier()
	if t == null:
		return
	var root := get_tree().root
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR if t.rendering_scale < 0.999 else Viewport.SCALING_3D_MODE_DISABLED
	root.scaling_3d_scale = clampf(t.rendering_scale, 0.3, 2.0)
	root.msaa_3d = Viewport.MSAA_DISABLED if t.msaa_3d <= 0 else (Viewport.MSAA_2X if t.msaa_3d == 1 else Viewport.MSAA_4X)
	root.use_occlusion_culling = t.occlusion_culling
	# Атлас направленных теней глобальный (не per-viewport), поэтому гоняем напрямую через
	# RenderingServer: 512 на low против 2048 на high - это ~16x памяти и work на Mali-G52.
	RenderingServer.directional_shadow_atlas_set_size(
		clampi(t.shadow_atlas_size, 256, 8192),
		ProjectSettings.get_setting_with_override("rendering/lights_and_shadows/directional_shadow/16_bits"),
	)
	# Фильтрация текстур: анизотропия - это отдельный режим фильтра, а не «ещё одна настройка».
	MaterialLibrary.set_texture_filter(5 if t.anisotropy > 0 else clampi(t.texture_filter, 0, 5))
	tier_changed.emit(tier_index, t)

func prop_density() -> float:
	var t := tier()
	return t.prop_density if t != null else 1.0

func cull_distance_multiplier() -> float:
	var t := tier()
	return t.cull_distance_multiplier if t != null else 1.0

func lod_bias() -> float:
	var t := tier()
	return t.lod_bias if t != null else 1.0

func max_chunks() -> int:
	var t := tier()
	# Игрок уехал по проспекту далеко от «дома своего чанка»: потолок качества не должен
	# давать выгружать чанки внутри радиуса загрузки, поэтому floor = размер кольца.
	return clampi(t.max_chunks if t != null else 9, 1, 64)

## Строить ли окклюдерные деревья чанков. На LOW экономия на построении важнее выгоды
## отсечения (там и так всё рядом), поэтому тешется отдельно от use_occlusion_culling.
func occluders_enabled() -> bool:
	var t := tier()
	return t.occlusion_culling if t != null else true

func shadows_enabled() -> bool:
	var t := tier()
	return t.shadows_enabled if t != null else true

func shadow_distance() -> float:
	var t := tier()
	return t.shadow_distance_m if t != null else 110.0

func fog_multiplier() -> float:
	var t := tier()
	return t.fog_density_multiplier if t != null else 1.0

func glow_enabled() -> bool:
	var t := tier()
	return t.glow_enabled if t != null else false

func anisotropy() -> int:
	var t := tier()
	return t.anisotropy if t != null else 0

func status_text() -> String:
	var t := tier()
	return "%s | %.0f fps | %.1f ms | %s" % [
		tier_name(), fps, avg_frame_ms, (t.describe() if t != null else "нет пресета"),
	]

func snapshot() -> Dictionary:
	return {
		"tier": tier_name(),
		"auto": auto and not manual_override,
		"fps": fps,
		"avg_frame_ms": avg_frame_ms,
		"downgrades": downgrades,
		"upgrades": upgrades,
		"device_hinted": configured_by_device,
	}
