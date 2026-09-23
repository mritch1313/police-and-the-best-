class_name DriveInput
extends RefCounted
## Один кадр водительского ввода. Чистый данные-объект: игрок, ИИ полиции и автотесты
## заполняют одни и те же поля, поэтому [VehiclePhysics] не различает «кто за рулём».
##
## Контракт:
##   throttle: -1..1 (0 = накат, >0 = газ, <0 = задняя передача)
##   brake:    0..1  (рабочий тормоз)
##   handbrake:0..1  (ручник; 1 = полностью заблокированная задняя ось)
##   steer:    -1..1 (>0 = вправо)
##   steer_absolute: если true, steer — уже абсолютный угол руля в радианах (для ИИ/отладки)

var throttle: float = 0.0
var brake: float = 0.0
var handbrake: float = 0.0
var steer: float = 0.0
var steer_absolute: bool = false
## Для телеметрии и отладки: кто именно водит.
var source: String = "none"
## Момент, когда ввод поменялся (используется детектором «застрял»).
var last_change_ms: int = 0

func reset() -> void:
	throttle = 0.0
	brake = 0.0
	handbrake = 0.0
	steer = 0.0
	steer_absolute = false

func is_empty() -> bool:
	return absf(throttle) < 0.001 and absf(brake) < 0.001 and absf(steer) < 0.001 and handbrake < 0.001

func clamp_all() -> void:
	throttle = clampf(throttle, -1.0, 1.0)
	brake = clampf(brake, 0.0, 1.0)
	handbrake = clampf(handbrake, 0.0, 1.0)
	steer = clampf(steer, -1.0, 1.0)

func touch_factor() -> bool:
	return source == "touch" or source == "keys" or source == "pad"

func to_dict() -> Dictionary:
	return {
		"throttle": throttle,
		"brake": brake,
		"handbrake": handbrake,
		"steer": steer,
		"source": source,
	}

func from_dict(data: Dictionary) -> void:
	throttle = float(data.get("throttle", 0.0))
	brake = float(data.get("brake", 0.0))
	handbrake = float(data.get("handbrake", 0.0))
	steer = float(data.get("steer", 0.0))
	source = str(data.get("source", "dict"))
	clamp_all()
