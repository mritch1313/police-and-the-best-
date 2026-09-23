class_name NitroSystem
extends Node
## Нитро: шкала заряда + множители, которые физика сама превращает в тягу и потолок скорости.
##
## Система НЕ двигает машину, НЕ пишет в трансформ и НЕ знает про RigidBody3D.
## Она лишь отвечает на два вопроса: «можно ли сейчас бустить» и «какие множители дать».
## Ограничение по времени реализовано как `max_burst_s` +пауза-охлаждение, а не «бесконечная кнопка».

signal state_changed(active: bool, charge_ratio: float)
signal depleted()
signal overheated()
signal burst_started()

var config: NitroConfig = null
## Заряд в тех же единицах, что `config.max_charge`.
var charge: float = 0.0
var active: bool = false
var burst_time: float = 0.0
var cooldown: float = 0.0
var idle_time: float = 0.0
## Внешний запрет (пауза, арест, нет машины).
var allowed: bool = true
## Запрошенное состояние — пишет [MobileControls]/[VehicleController]/харнесс.
var requested: bool = false
## Статистика заезда (для HUD и `AppState`).
var used_count: int = 0
var total_boost_time: float = 0.0

func _ready() -> void:
	if config == null:
		var setup := get_node_or_null("/root/GameSetup")
		if setup != null:
			config = setup.get("nitro") as NitroConfig
	if config == null:
		push_warning("NitroSystem: NitroConfig не назначен — нитро будет выключено")
	if config != null:
		charge = config.max_charge

func _physics_process(delta: float) -> void:
	if config == null:
		return
	var was_active := active
	var can_drain := allowed and config.enabled and AppState.can_use_nitro()

	if cooldown > 0.0:
		cooldown = maxf(cooldown - delta, 0.0)
		active = false

	var wants := requested and can_drain and cooldown <= 0.0
	if wants and not active:
		if charge >= config.min_to_start:
			active = true
			burst_time = 0.0
			used_count += 1
			burst_started.emit()
		else:
			active = false

	if active:
		charge = maxf(charge - config.drain_per_s * delta, 0.0)
		burst_time += delta
		total_boost_time += delta
		idle_time = 0.0
		if config.max_burst_s > 0.0 and burst_time >= config.max_burst_s:
			active = false
			cooldown = config.overheat_cooldown_s
			overheated.emit()
		if charge <= 0.01:
			charge = 0.0
			active = false
			cooldown = config.overheat_cooldown_s * 0.5
			depleted.emit()
	elif not wants:
		idle_time += delta
		if idle_time >= config.regen_delay_s and charge < config.max_charge:
			charge = minf(charge + config.regen_per_s * delta, config.max_charge)

	if active and charge < config.min_sustained:
		active = false
		charge = maxf(charge, 0.0)
		depleted.emit()

	if was_active != active:
		state_changed.emit(active, charge_ratio())

## Единственная точка, через которую нитро влияет на движение.
func physics_multipliers() -> Dictionary:
	if config == null:
		return {"speed": 1.0, "thrust": 1.0, "grip": 1.0, "drag": 1.0}
	if not active:
		return {"speed": 1.0, "thrust": 1.0, "grip": 1.0, "drag": 1.0}
	return {
		"speed": config.max_speed_multiplier,
		"thrust": config.thrust_multiplier,
		"grip": config.grip_multiplier,
		"drag": config.drag_multiplier,
	}

## 0..1 — шкала для мягкого FOV/визуала (не зависит от `active`, чтобы не «мигало»).
func visual_intensity() -> float:
	if config == null or not config.enabled:
		return 0.0
	return clampf(1.0 if active else 0.0, 0.0, 1.0)

func charge_ratio() -> float:
	if config == null:
		return 0.0
	return clampf(charge / maxf(config.max_charge, 1.0), 0.0, 1.0)

func is_ready() -> bool:
	return config != null and config.enabled and allowed and cooldown <= 0.0 and charge >= config.min_to_start

func is_blocked_by_overheat() -> bool:
	return cooldown > 0.0

func set_requested(p_requested: bool) -> void:
	if p_requested == requested:
		return
	requested = p_requested

func refill() -> void:
	if config != null:
		charge = config.max_charge
		cooldown = 0.0
		idle_time = 0.0

func apply_config(p_config: NitroConfig) -> void:
	config = p_config
	if config != null:
		charge = clampf(charge, 0.0, config.max_charge)
		if charge == 0.0:
			charge = config.max_charge

## Точка входа для тестов: один шаг симуляции без NodeTree.
static func simulate_step(state: Dictionary, cfg: NitroConfig, requested_now: bool, delta: float) -> Dictionary:
	var out: Dictionary = state.duplicate()
	var charge := float(out.get("charge", cfg.max_charge))
	var active := bool(out.get("active", false))
	var cooldown := float(out.get("cooldown", 0.0))
	var idle := float(out.get("idle_time", 0.0))
	var burst := float(out.get("burst_time", 0.0))
	if cooldown > 0.0:
		cooldown = maxf(cooldown - delta, 0.0)
		active = false
	var wants := requested_now and cfg.enabled and cooldown <= 0.0
	if wants and not active and charge >= cfg.min_to_start:
		active = true
		burst = 0.0
	if active:
		charge = maxf(charge - cfg.drain_per_s * delta, 0.0)
		burst += delta
		idle = 0.0
		if cfg.max_burst_s > 0.0 and burst >= cfg.max_burst_s:
			active = false
			cooldown = cfg.overheat_cooldown_s
		elif charge <= 0.001:
			charge = 0.0
			active = false
			cooldown = cfg.overheat_cooldown_s * 0.5
	elif not wants:
		idle += delta
		if idle >= cfg.regen_delay_s and charge < cfg.max_charge:
			charge = minf(charge + cfg.regen_per_s * delta, cfg.max_charge)
	if active and charge < cfg.min_sustained:
		active = false
	out["charge"] = charge
	out["active"] = active
	out["cooldown"] = cooldown
	out["idle_time"] = idle
	out["burst_time"] = burst
	out["multipliers"] = {"speed": cfg.max_speed_multiplier if active else 1.0, "thrust": cfg.thrust_multiplier if active else 1.0}
	return out
