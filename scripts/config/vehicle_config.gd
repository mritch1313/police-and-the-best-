class_name VehicleConfig
extends ConfigResource
## Полный набор настраиваемых параметров одного автомобиля.
##
## Единицы СИ везде, кроме скоростей (км/ч) и углов (градусы) — так конфиг читается людьми.
## Модель шин: линейная (угловая жёсткость) + круг трения, поэтому `grip_*_mu`,
## `*_stiffness_*` и `mass_kg` вместе определяют занос, срыв и возврат из него.
## Всё, что нужно для замены визуальной модели, лежит в `visual_scene` — физика об этом не знает.

@export_group("Identity")
## Отображаемое имя (для HUD/логов).
@export var display_name: String = "Седан угонщика"
## Визуальная модель. Если пусто — используется процедурная модель `ProceduralVehicleModel`.
## Положи сюда свой .glb/.gltf-префаб и назови колёса `Wheel_FL`, `Wheel_FR`, `Wheel_RL`, `Wheel_RR`.
@export var visual_scene: PackedScene

@export_group("Mass and shape")
@export_range(400.0, 3600.0, 1.0, "or_greater") var mass_kg: float = 1380.0
## Смещение центра тяжести вниз от геометрического центра кузова (больше = устойчивее, меньше кренов).
@export_range(0.0, 1.2, 0.01) var center_of_mass_drop_m: float = 0.34
@export_range(1.6, 4.2, 0.01) var wheelbase_m: float = 2.74
@export_range(1.1, 2.4, 0.01) var track_width_m: float = 1.6
@export_range(0.12, 0.6, 0.01) var ride_height_m: float = 0.3
@export_range(0.25, 0.65, 0.005) var wheel_radius_m: float = 0.33
@export_range(0.1, 0.5, 0.01) var wheel_width_m: float = 0.24

@export_group("Drivetrain")
## Пиковая тяга в пятнах контакта ведущих колёс (Н).
@export_range(0.0, 40000.0, 50.0, "or_greater") var engine_force_n: float = 13500.0
@export_range(0.1, 1.0, 0.01) var reverse_ratio: float = 0.42
@export_range(0.0, 1.0, 0.01) var drive_bias_front: float = 0.0
## Сопротивление двигателя на нейтрали/газе-впол (Н·м на колесо).
@export_range(0.0, 400.0, 1.0) var engine_brake_torque_nm: float = 42.0
@export_range(600.0, 2000.0, 10.0) var idle_rpm: float = 820.0
@export_range(4000.0, 12000.0, 100.0) var redline_rpm: float = 6600.0
@export var gear_ratios: Array[float] = [3.62, 2.19, 1.41, 1.0, 0.78]
@export_range(2.0, 6.0, 0.05) var final_drive: float = 3.92
@export_range(0.0, 0.6, 0.01) var shift_time_s: float = 0.14

@export_group("Speed limits")
## Максимальная скорость без нитро (км/ч). Полиция по замыслу чуть быстрее — см. PoliceConfig.
@export_range(40.0, 400.0, 1.0, "or_greater") var max_speed_kmh: float = 165.0
## Скорость, ниже которой тяга почти не зависит от скорости (полка момента).
@export_range(5.0, 300.0, 1.0) var throttle_ref_speed_kmh: float = 96.0
## Пассивное замедление (Н·м/м² условная аэродинамика).
@export_range(0.0, 15.0, 0.05) var drag_coefficient: float = 1.35
## Постоянное сопротивление качению (Н).
@export_range(0.0, 2000.0, 5.0) var rolling_resistance_n: float = 380.0
## Прижимная сила на м²/скорость² — держит машину на поверхности на высокой скорости.
@export_range(0.0, 4.0, 0.01) var downforce_k: float = 0.55

@export_group("Brakes")
## Тормозное усилие на колесо (Н) — пересчитывается в тормозной момент радиусом колеса.
@export_range(0.0, 20000.0, 50.0) var brake_force_n: float = 9200.0
## Усилие ручника (только задняя ось).
@export_range(0.0, 20000.0, 50.0) var handbrake_force_n: float = 6200.0

@export_group("Steering")
@export_range(8.0, 45.0, 0.5) var max_steer_deg: float = 37.0
@export_range(3.0, 30.0, 0.5) var min_steer_deg: float = 13.0
## Скорость, на которой угол руля уже минимальный.
@export_range(20.0, 320.0, 1.0) var steer_at_full_speed_kmh: float = 150.0
@export_range(20.0, 600.0, 5.0) var steer_speed_in_deg_s: float = 260.0
@export_range(20.0, 900.0, 5.0) var steer_speed_out_deg_s: float = 420.0
@export_range(0.0, 30.0, 0.5) var steer_return_deadzone_kmh: float = 3.0

@export_group("Tyres")
@export_range(0.3, 2.5, 0.01) var grip_front_mu: float = 1.18
@export_range(0.3, 2.5, 0.01) var grip_rear_mu: float = 1.12
## Коэффициент сцепления задней оси при нажатом ручнике (меньше = легче пускать машину боком).
@export_range(0.05, 1.5, 0.01) var grip_handbrake_mu: float = 0.42
## Боковая жёсткость шины (Н на рад угла увода).
@export_range(2000.0, 200000.0, 500.0) var corner_stiffness_n_per_rad: float = 62000.0
## Продольная жёсткость шины (Н на единицу пробуксовки).
@export_range(2000.0, 200000.0, 500.0) var longitudinal_stiffness_n: float = 68000.0

@export_group("Suspension")
@export_range(0.03, 0.6, 0.005) var suspension_travel_m: float = 0.17
## Собственная частота подвески (Гц) — из неё считается жёсткость пружины.
@export_range(0.5, 5.0, 0.05) var suspension_frequency_hz: float = 1.7
@export_range(0.05, 1.2, 0.01) var damper_ratio: float = 0.34
@export_range(0.0, 120000.0, 500.0) var anti_roll_front_n: float = 26000.0
@export_range(0.0, 120000.0, 500.0) var anti_roll_rear_n: float = 18000.0
## Жёсткость стабилизатора на метр хода подвески (Н/м).
@export_range(0.0, 1.0, 0.01) var bump_damping_extra: float = 0.18

@export_group("Collision")
## 1=World, 2=PlayerCar, 3=PoliceCar, 4=Prop, 5=Trigger (см. layer_names в project.godot).
@export_range(1, 32, 1) var collision_layer: int = 2
@export_range(1, 1023, 1) var collision_mask: int = 29  # 1|4|8|16: World|Prop|Trigger
## Маска лучей подвески (по умолчанию только мир + реквизит).
@export_range(1, 1023, 1) var wheel_ray_mask: int = 21  # 1|4|16: World|Prop|Trigger


## Перекрёстные проверки связности — конфиг может быть синтаксически валидным,
## но физически бессмысленным. Проблемы видны в DebugConsole и валят CI-тест конфигурации.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if wheelbase_m <= 2.0 * wheel_radius_m:
		problems.append(_problem("wheelbase_m (%.2f) не больше диаметра колеса (%.2f)" % [wheelbase_m, 2.0 * wheel_radius_m]))
	if track_width_m <= 2.0 * wheel_width_m:
		problems.append(_problem("track_width_m (%.2f) уже двух колёс (%.2f)" % [track_width_m, 2.0 * wheel_width_m]))
	if mass_kg < 400.0:
		problems.append(_problem("mass_kg=%.1f: физика будет «бумажной»" % mass_kg))
	if engine_force_n / mass_kg < 1.2:
		problems.append(_problem("тяга %.0f Н на %.0f кг: машина не сможет разогнаться" % [engine_force_n, mass_kg]))
	if min_steer_deg > max_steer_deg:
		problems.append(_problem("min_steer_deg (%.1f) больше max_steer_deg (%.1f)" % [min_steer_deg, max_steer_deg]))
	if ride_height_m < wheel_radius_m * 0.45:
		problems.append(_problem("ride_height_m=%.2f: кузов упрётся в асфальт (радиус колеса %.2f)" % [ride_height_m, wheel_radius_m]))
	if suspension_travel_m <= 0.01 or longitudinal_stiffness_n <= 0.0 or corner_stiffness_n_per_rad <= 0.0:
		problems.append(_problem("подвеска/шины не могут иметь нулевую жёсткость"))
	if gear_ratios.is_empty():
		problems.append(_problem("gear_ratios пуст — передаточное число не определено"))
	elif gear_ratios.size() >= 2 and gear_ratios[0] <= gear_ratios[1]:
		problems.append(_problem("gear_ratios должны идти от большего к меньшему"))
	if collision_mask == 0:
		problems.append(_problem("collision_mask=0: машина не увидит дорогу"))
	return problems


## Максимальная скорость в м/с (используется физикой, полицией и тестами).
func max_speed_kms() -> float:
	return max_speed_kmh / 3.6


func nitro_speed_kms(nitro_multiplier: float) -> float:
	return max_speed_kms() * nitro_multiplier


## Удельная тяга (Н на кг) — convenient scalar for AI comparisons.
func power_to_weight() -> float:
	return engine_force_n / maxf(mass_kg, 1.0)


## Жёсткость пружины одного колеса (Н/м) из частоты и массы угла кузова.
func spring_rate_n_per_m() -> float:
	var corner_mass := mass_kg / 4.0
	return corner_mass * pow(TAU * suspension_frequency_hz, 2.0)


## Демпфирование одного колеса (Н·с/м) из коэффициента демпфирования.
func damper_rate_n_s_per_m() -> float:
	var corner_mass := mass_kg / 4.0
	var k := spring_rate_n_per_m()
	return 2.0 * damper_ratio * sqrtf(maxf(k * corner_mass, 0.0001))


## Тормозной момент на колесо (Н·м).
func brake_torque_nm(per_handbrake: bool = false) -> float:
	return (handbrake_force_n if per_handbrake else brake_force_n) * wheel_radius_m
